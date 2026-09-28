using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.Extensions.Caching.Memory;

namespace CoreReporting.Services;

/// <summary>
/// Assembles the Item Costing Recon dashboard from
/// dbo.sp_rpt_ItemCostingRecon_List (ERP-owned, read-only — see
/// docs/ItemCostingRecon_WebReporting_Handoff.md) and computes the KPI tiles
/// in C# per the handoff doc §5's exact formulas.
///
/// The data "changes only when expenses or payments are posted" (handoff
/// doc §7), so the cache window here is longer than the 2-minute window the
/// Executive/Accounting dashboards use for ledger data that moves every
/// posting. "Refresh" from the view bypasses it, same pattern as
/// ExecutiveDashboardService.BuildAsync.
/// </summary>
public sealed class ItemCostingReconService
{
    private readonly IReportRepository _repo;
    private readonly IMemoryCache _cache;
    private readonly ILogger<ItemCostingReconService> _log;

    private static readonly TimeSpan CacheWindow = TimeSpan.FromMinutes(10);

    public ItemCostingReconService(
        IReportRepository repo, IMemoryCache cache, ILogger<ItemCostingReconService> log)
    {
        _repo = repo;
        _cache = cache;
        _log = log;
    }

    private static string KeyFor(DateOnly dateFrom, DateOnly dateTo, string? shipmentNo) =>
        $"itemcostingrecon::{dateFrom:yyyyMMdd}::{dateTo:yyyyMMdd}::{shipmentNo ?? "ALL"}";

    public async Task<ItemCostingReconViewModel> BuildAsync(
        DateOnly dateFrom, DateOnly dateTo, string? shipmentNo, bool forceRefresh,
        CancellationToken ct = default)
    {
        var key = KeyFor(dateFrom, dateTo, shipmentNo);

        if (forceRefresh)
            _cache.Remove(key);

        if (_cache.TryGetValue(key, out ItemCostingReconViewModel? cached) && cached is not null)
            return cached;

        var sw = System.Diagnostics.Stopwatch.StartNew();

        // Always @OnlyWithExpenses = 1 — per handoff doc §5, NO EXPENSES rows
        // never enter this dashboard's data (they'd add meaningless variance,
        // ~406M of it on DEV). This is not an exposed toggle in this build.
        var (shipments, expenses) = await _repo.GetItemCostingReconAsync(
            dateFrom, dateTo, shipmentNo, onlyWithExpenses: true, ct);

        var varianceRows = shipments.Where(s => s.ReconStatus == "VARIANCE").ToList();

        var vm = new ItemCostingReconViewModel
        {
            DateFrom = dateFrom,
            DateTo = dateTo,
            ShipmentNo = shipmentNo,
            Shipments = shipments,
            Expenses = expenses,

            ShipmentsReconciled = shipments.Count,
            // count(ReconStatus == "MATCHED"), NOT count(IsMatched): the proc's
            // own classification (handoff doc §4) applies NO INVENTORY/LOTS
            // DIVERGE before the tolerance test that sets IsMatched, so a
            // shipment can have IsMatched=1 (e.g. TotalQty=0 makes Variance
            // algebraically 0) while ReconStatus is "NO INVENTORY", not
            // "MATCHED". The doc's own KPI formula is explicit: by status
            // label, not by the flag. IsMatched and ReconStatus=="MATCHED"
            // happen to agree on today's data (0 LOTS DIVERGE/NO INVENTORY
            // rows) — that coincidence is exactly what made this bug easy to
            // miss; don't revert to IsMatched even though it "looks" simpler.
            MatchRatePct = shipments.Count == 0
                ? 0m
                : Math.Round(shipments.Count(s => s.ReconStatus == "MATCHED") * 100m / shipments.Count, 2),
            ShipmentsNeedingAttention = shipments.Count(s =>
                s.ReconStatus is "VARIANCE" or "LOTS DIVERGE" or "NO INVENTORY"),
            InventoryCostFromExpenses = shipments.Sum(s => s.TotalInventoryCost),
            NetVarianceValue = varianceRows.Sum(s => s.VarianceValue),
            GrossVarianceExposure = varianceRows.Sum(s => Math.Abs(s.VarianceValue)),

            GeneratedAt = DateTime.Now
        };

        sw.Stop();
        _log.LogInformation("Item Costing Recon dashboard built in {Ms} ms for {Key}",
            sw.ElapsedMilliseconds, key);

        _cache.Set(key, vm, CacheWindow);
        return vm;
    }
}
