using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;

namespace CoreReporting.Services;

/// <summary>
/// Assembles the Supplier Price Comparison page from
/// dbo.sp_rpt_SupplierPriceComparison (sql/29) and cross-checks each
/// shipment against the ERP's own dbo.sp_rpt_ItemCostingRecon_List for the
/// same PO-date range.
///
/// Why the cross-check: sql/29 computes the INVOICE basis the client asked
/// for (all linked ExpenseSummary.Amount / received kg). The recon proc
/// holds the other basis, the part of those invoices actually capitalised
/// to inventory (excludes recoverable VAT and non-inventory lines). Showing
/// both side by side lets a reader see when a supplier "looks" expensive
/// only because its invoices carry VAT. And comparing the two procs'
/// invoice totals per shipment (LinkCheck) proves both found the same
/// invoices. The recon proc is ERP-owned, so it is read as-is, never
/// recomputed. If it's missing on the target DB, the page still works and
/// says the cross-check is unavailable.
/// </summary>
public sealed class SupplierPriceService
{
    private readonly IReportRepository _repo;
    private readonly IMemoryCache _cache;
    private readonly ILogger<SupplierPriceService> _log;

    // Same window as Item Costing Recon: this data moves only when an
    // expense invoice is posted or a PO is received.
    private static readonly TimeSpan CacheWindow = TimeSpan.FromMinutes(10);

    /// <summary>One peso of tolerance per shipment when comparing invoice
    /// totals between the two procs (both are sums of money columns, so any
    /// real difference is a missing/extra invoice, not rounding).</summary>
    private const decimal LinkTolerance = 1.00m;

    public SupplierPriceService(IReportRepository repo, IMemoryCache cache, ILogger<SupplierPriceService> log)
    {
        _repo = repo;
        _cache = cache;
        _log = log;
    }

    private static string KeyFor(DateOnly from, DateOnly to, PricePeriod period, string? product) =>
        $"supplierprice::{from:yyyyMMdd}::{to:yyyyMMdd}::{period.Code()}::{product ?? "ALL"}";

    /// <summary>Default range per grain: enough buckets to see a trend
    /// without an unreadable chart.</summary>
    public static DateOnly DefaultFrom(PricePeriod period, DateOnly today) => period switch
    {
        // 12 whole weeks, snapped back to a Monday so the first bucket
        // isn't a partial week (the proc's weeks start on Monday).
        PricePeriod.Weekly => today.AddDays(-7 * 12 - ((int)today.DayOfWeek + 6) % 7),
        PricePeriod.Yearly => new DateOnly(today.Year - 2, 1, 1),                // 3 calendar years
        _ => new DateOnly(today.Year, today.Month, 1).AddMonths(-11)             // 12 months
    };

    public async Task<SupplierPriceViewModel> BuildAsync(
        DateOnly dateFrom, DateOnly dateTo, PricePeriod period, string? productCode,
        bool forceRefresh, CancellationToken ct = default)
    {
        productCode = string.IsNullOrWhiteSpace(productCode) ? null : productCode.Trim();
        var key = KeyFor(dateFrom, dateTo, period, productCode);

        if (forceRefresh)
            _cache.Remove(key);

        if (_cache.TryGetValue(key, out SupplierPriceViewModel? cached) && cached is not null)
            return cached;

        var sw = System.Diagnostics.Stopwatch.StartNew();

        var data = await _repo.GetSupplierPriceComparisonAsync(
            dateFrom, dateTo, period, productCode: productCode, ct: ct);

        var reconAvailable = await ApplyReconCrossCheckAsync(data.Shipments, dateFrom, dateTo, ct);

        var priced = data.Shipments.Where(s => s.PriceStatus == "PRICED").ToList();
        var kg = priced.Sum(s => s.ReceivedKg);
        var landed = priced.Sum(s => s.TotalLandedAmount);
        var addOn = priced.Sum(s => s.AddOnAmount);

        var vm = new SupplierPriceViewModel
        {
            DateFrom = dateFrom,
            DateTo = dateTo,
            Period = period,
            ProductCode = productCode,
            Data = data,
            SupplierRange = RollUpBySupplier(priced),

            PricedShipments = priced.Count,
            NotReceivedShipments = data.Shipments.Count(s => s.PriceStatus == "NOT RECEIVED"),
            IncompleteShipments = data.Shipments.Count(s => s.PriceStatus == "INCOMPLETE"),
            NoPoLineShipments = data.Shipments.Count(s => s.PriceStatus == "NO PO LINES"),
            MixedShipments = priced.Count(s => s.IsMultiProduct),
            ReceivedKg = kg,
            TotalLandedAmount = landed,
            WeightedLandedPerKg = kg == 0 ? null : Math.Round(landed / kg, 4),
            AddOnSharePct = landed == 0 ? null : Math.Round(addOn * 100m / landed, 2),
            UnpostedInvoices = priced.Sum(s => s.UnpostedExpenseCount),

            ReconCrossCheckAvailable = reconAvailable,
            LinkDiffers = data.Shipments.Count(s => s.LinkCheck == "DIFFERS"),

            GeneratedAt = DateTime.Now
        };

        sw.Stop();
        _log.LogInformation("Supplier Price Comparison built in {Ms} ms for {Key}", sw.ElapsedMilliseconds, key);

        _cache.Set(key, vm, CacheWindow);
        return vm;
    }

    /// <summary>Whole-range weighted ₱/kg per PO supplier, priced shipments
    /// only, cheapest first. Public so Hey Jude ranks suppliers the same way
    /// the page does.</summary>
    public static IReadOnlyList<SupplierRangeRow> RollUpBySupplier(IEnumerable<PriceShipmentRow> priced) =>
        priced
            .Where(s => s.PriceStatus == "PRICED")
            .GroupBy(s => s.SupplierId)
            .Select(g => new SupplierRangeRow
            {
                SupplierId = g.Key,
                SupplierName = g.First().SupplierName,
                Shipments = g.Count(),
                MixedShipments = g.Count(s => s.IsMultiProduct),
                ReceivedKg = g.Sum(s => s.ReceivedKg),
                TotalLandedAmount = g.Sum(s => s.TotalLandedAmount),
                SupplierInvoiceAmount = g.Sum(s => s.SupplierInvoiceAmount),
                AddOnAmount = g.Sum(s => s.AddOnAmount)
            })
            .OrderBy(x => x.LandedCostPerKg)
            .ToList();

    /// <summary>Fills InventoryCostedPerKg / ReconInvoiceAmount / LinkCheck on
    /// each shipment. Returns false (and marks every row UNAVAILABLE) when
    /// the recon proc can't be read — a missing ERP proc must not take the
    /// whole page down.</summary>
    private async Task<bool> ApplyReconCrossCheckAsync(
        IReadOnlyList<PriceShipmentRow> shipments, DateOnly from, DateOnly to, CancellationToken ct)
    {
        if (shipments.Count == 0)
            return true;

        Dictionary<string, ReconShipmentRow> recon;
        HashSet<string> dupes;
        try
        {
            var (reconShipments, _) = await _repo.GetItemCostingReconAsync(
                from, to, shipmentNo: null, onlyWithExpenses: true, ct);
            // A shipment the recon returns twice is itself a finding: flag
            // it DUPLICATE IN RECON rather than silently picking one row.
            var groups = reconShipments.GroupBy(r => r.ShipmentNo).ToList();
            dupes = groups.Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
            recon = groups.ToDictionary(g => g.Key, g => g.First());
        }
        catch (SqlException ex)
        {
            _log.LogWarning(ex, "Item Costing Recon cross-check unavailable for Supplier Price Comparison");
            foreach (var s in shipments)
                s.LinkCheck = "UNAVAILABLE";
            return false;
        }

        foreach (var s in shipments)
        {
            if (!recon.TryGetValue(s.ShipmentNo, out var r))
            {
                s.LinkCheck = "NOT IN RECON";
                continue;
            }

            if (dupes.Contains(s.ShipmentNo))
            {
                s.LinkCheck = "DUPLICATE IN RECON";
                continue;
            }

            s.ReconInvoiceAmount = r.TotalInvoiceAmount;
            s.ReconQty = r.TotalQty;
            // The recon's inventory-capitalised pesos divided by THIS
            // report's received kg, so the gap against LandedCostPerKg is
            // purely VAT/non-inventory lines, not a different quantity base
            // (the recon divides by Inventory.Quantity). A quantity
            // difference is flagged separately via ReconQty.
            s.InventoryCostedPerKg = s.ReceivedKg > 0
                ? Math.Round(r.TotalInventoryCost / s.ReceivedKg, 4)
                : null;
            var sameInvoices = r.LinkedExpenseCount == s.ExpenseCount &&
                               Math.Abs(r.TotalInvoiceAmount - s.TotalLandedAmount) <= LinkTolerance;
            s.LinkCheck = sameInvoices ? "MATCHES" : "DIFFERS";
        }

        return true;
    }
}
