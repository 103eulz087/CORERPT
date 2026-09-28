using ClosedXML.Excel;
using CoreReporting.Models;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CoreReporting.Controllers;

/// <summary>
/// Supplier Price Comparison: landed cost per kg by supplier, weekly /
/// monthly / yearly, over dbo.sp_rpt_SupplierPriceComparison (sql/29).
///
/// Does NOT inherit FilterAwareController: its date range is a PO-order
/// range with its own period grain (W/M/Y), not the shared session
/// Period/Branch filter. Same split as ItemCostingReconController.
/// </summary>
[Authorize(Roles = "Executive,Accounting,Audit,Operations")]
public sealed class SupplierPriceController : Controller
{
    private readonly SupplierPriceService _svc;

    public SupplierPriceController(SupplierPriceService svc) => _svc = svc;

    public async Task<IActionResult> Index(
        DateOnly? dateFrom, DateOnly? dateTo, string? period, string? productCode, bool force,
        CancellationToken ct)
    {
        var (from, to, grain) = Resolve(dateFrom, dateTo, period);
        var vm = await _svc.BuildAsync(from, to, grain, productCode, force, ct);
        return View(vm);
    }

    /// <summary>Same data as the page, one sheet per result set, so the
    /// client can pivot and chart it in Excel themselves.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportExcel(
        DateOnly? dateFrom, DateOnly? dateTo, string? period, string? productCode, CancellationToken ct)
    {
        var (from, to, grain) = Resolve(dateFrom, dateTo, period);
        var vm = await _svc.BuildAsync(from, to, grain, productCode, forceRefresh: false, ct);

        using var wb = new XLWorkbook();

        var subtitle = $"{grain.Label()} · PO date {from:yyyy-MM-dd} to {to:yyyy-MM-dd}" +
                       (string.IsNullOrWhiteSpace(vm.ProductCode) ? "" : $" · product {vm.ProductCode}");
        const string basis =
            "Landed cost per kg = linked ExpenseSummary invoice amounts / received kg (invoice basis: " +
            "includes any recoverable VAT). Weighted by kg. Mixed-product shipments carry one blended ₱/kg.";

        AddSheet(wb, "Supplier by period", subtitle, basis,
            new[]
            {
                "Period", "Supplier ID", "Supplier", "Shipments", "Mixed-product shipments", "Received kg",
                "Supplier invoices ₱", "Add-ons ₱", "Total landed ₱", "Landed ₱/kg", "Supplier price ₱/kg",
                "Add-on ₱/kg", "Min shipment ₱/kg", "Max shipment ₱/kg", "Period avg ₱/kg (all suppliers)",
                "vs period avg %", "Rank in period", "Suppliers in period", "Previous period", "Prev ₱/kg", "Change %"
            },
            vm.Data.SupplierPeriods.Select(x => new object?[]
            {
                x.PeriodLabel, x.SupplierId, x.SupplierName, x.Shipments, x.MixedShipments, x.ReceivedKg,
                x.SupplierInvoiceAmount, x.AddOnAmount, x.TotalLandedAmount, x.LandedCostPerKg,
                x.SupplierPricePerKg, x.AddOnPerKg, x.MinShipmentPerKg, x.MaxShipmentPerKg, x.PeriodAvgPerKg,
                x.VsPeriodAvgPct, x.RankInPeriod, x.SuppliersInPeriod, x.PrevPeriodStart, x.PrevLandedPerKg, x.ChangePct
            }),
            textColumns: new[] { 2 });

        AddSheet(wb, "Product by supplier", subtitle,
            "Single-product shipments only: the like-for-like comparison. Mixed shipments are excluded, not allocated.",
            new[]
            {
                "Period", "Product code", "Product", "Supplier ID", "Supplier", "Shipments", "Received kg",
                "Total landed ₱", "Landed ₱/kg", "Supplier price ₱/kg", "Best ₱/kg (this product, period)",
                "vs best %", "Rank", "Suppliers for product", "Previous period", "Prev ₱/kg", "Change %"
            },
            vm.Data.ProductPeriods.Select(x => new object?[]
            {
                x.PeriodLabel, x.ProductCode, x.ProductDescription, x.SupplierId, x.SupplierName, x.Shipments,
                x.ReceivedKg, x.TotalLandedAmount, x.LandedCostPerKg, x.SupplierPricePerKg, x.BestPerKg,
                x.VsBestPct, x.RankForProduct, x.SuppliersForProduct, x.PrevPeriodStart, x.PrevLandedPerKg, x.ChangePct
            }),
            textColumns: new[] { 2, 4 });

        AddSheet(wb, "Shipments", subtitle, basis,
            new[]
            {
                "Shipment", "Period", "PO date", "Branch code", "Branch", "Supplier ID", "Supplier", "PO status",
                "Product", "Products", "Ordered kg", "Received kg", "Invoices", "Unposted invoices",
                "Supplier invoices ₱", "Add-ons ₱", "Total landed ₱", "Supplier price ₱/kg", "Add-on ₱/kg",
                "Landed ₱/kg", "Inventory-costed ₱/kg (ERP recon)", "Recon invoice total ₱", "Link check", "Price status"
            },
            vm.Data.Shipments.Select(x => new object?[]
            {
                x.ShipmentNo, x.PeriodLabel, x.DateOrder, x.BranchCode, x.BranchName, x.SupplierId, x.SupplierName,
                x.PoStatus, x.ProductDescription, x.ProductCount, x.OrderedKg, x.ReceivedKg, x.ExpenseCount,
                x.UnpostedExpenseCount, x.SupplierInvoiceAmount, x.AddOnAmount, x.TotalLandedAmount,
                x.SupplierPricePerKg, x.AddOnPerKg, x.LandedCostPerKg, x.InventoryCostedPerKg,
                x.ReconInvoiceAmount, x.LinkCheck, x.PriceStatus
            }),
            textColumns: new[] { 1, 4, 6 });

        AddSheet(wb, "Invoices", subtitle,
            "Every ExpenseSummary invoice linked to the shipments above. Cost role SUPPLIER = invoiced by the PO supplier.",
            new[]
            {
                "Shipment", "Reference", "Invoice no", "Invoice supplier ID", "Invoice supplier", "Invoice date",
                "Description", "Status", "Posted to GL", "Amount ₱", "Cost role"
            },
            vm.Data.Expenses.Select(x => new object?[]
            {
                x.ShipmentNo, x.ReferenceNumber, x.InvoiceNo, x.ExpenseSupplierId, x.ExpenseSupplierName,
                x.ExpenseDate, x.Description, x.ExpenseStatus, x.IsPostedToGl ? "Yes" : "No", x.Amount, x.CostRole
            }),
            textColumns: new[] { 1, 2, 3, 4 });

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        var fileName = $"SupplierPriceComparison_{grain.Code()}_{from:yyyyMMdd}_{to:yyyyMMdd}.xlsx";
        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
    }

    private static (DateOnly From, DateOnly To, PricePeriod Period) Resolve(
        DateOnly? dateFrom, DateOnly? dateTo, string? period)
    {
        var grain = PricePeriodExtensions.Parse(period);
        var today = DateOnly.FromDateTime(DateTime.Today);
        var to = dateTo ?? today;
        var from = dateFrom ?? SupplierPriceService.DefaultFrom(grain, to);
        if (from > to) (from, to) = (to, from);
        return (from, to, grain);
    }

    /// <summary>One header block + table per sheet. Decimals get #,##0.00 or
    /// #,##0.0000 by header (₱/kg and % columns), dates yyyy-mm-dd, and the
    /// 1-based columns in textColumns are written as text so codes like
    /// branch '001' keep their leading zeros.</summary>
    private static void AddSheet(
        XLWorkbook wb, string name, string subtitle, string note, string[] headers,
        IEnumerable<object?[]> rows, int[]? textColumns = null)
    {
        var ws = wb.AddWorksheet(name);
        ws.Cell(1, 1).Value = $"Supplier Price Comparison — {name}";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Value = subtitle;
        ws.Cell(3, 1).Value = note;
        ws.Cell(4, 1).Value = $"Generated: {DateTime.Now:yyyy-MM-dd HH:mm}";

        const int headerRow = 6;
        for (var c = 0; c < headers.Length; c++)
        {
            ws.Cell(headerRow, c + 1).Value = headers[c];
            ws.Cell(headerRow, c + 1).Style.Font.Bold = true;
        }

        var text = new HashSet<int>(textColumns ?? Array.Empty<int>());
        var r = headerRow + 1;
        foreach (var row in rows)
        {
            for (var c = 0; c < row.Length; c++)
            {
                var cell = ws.Cell(r, c + 1);
                var h = headers[c];
                switch (row[c])
                {
                    case null:
                        break;
                    case string s when text.Contains(c + 1):
                        cell.SetValue(s);
                        cell.Style.NumberFormat.Format = "@";
                        break;
                    case string s:
                        cell.Value = s;
                        break;
                    case decimal d:
                        cell.Value = d;
                        cell.Style.NumberFormat.Format =
                            h.Contains('%') ? "0.00" :
                            h.Contains("/kg") ? "#,##0.0000" :
                            h.EndsWith(" kg") ? "#,##0.000" : "#,##0.00";
                        break;
                    case int i:
                        cell.Value = i;
                        break;
                    case DateTime dt:
                        cell.Value = dt;
                        cell.Style.NumberFormat.Format = "yyyy-mm-dd";
                        break;
                    default:
                        cell.Value = row[c]!.ToString();
                        break;
                }
            }
            r++;
        }

        if (r > headerRow + 1)
            ws.Range(headerRow, 1, r - 1, headers.Length).SetAutoFilter();
        ws.SheetView.FreezeRows(headerRow);
        ws.Columns().AdjustToContents(headerRow, Math.Max(headerRow, r - 1));
    }
}
