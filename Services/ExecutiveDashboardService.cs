using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.Extensions.Caching.Memory;

namespace CoreReporting.Services;

/// <summary>
/// Assembles the executive dashboard and caches it briefly.
///
/// The refresh model: the browser polls every 5 minutes, and cheap tiles
/// would otherwise re-scan the ledger for every user on every poll. A short
/// cache keyed on the filter means twenty executives looking at the same
/// month share one query. "Refresh" from the top bar bypasses it.
/// </summary>
public sealed class ExecutiveDashboardService
{
    private readonly IReportRepository _repo;
    private readonly IMemoryCache _cache;
    private readonly ILogger<ExecutiveDashboardService> _log;

    private static readonly TimeSpan CacheWindow = TimeSpan.FromMinutes(2);

    public ExecutiveDashboardService(
        IReportRepository repo, IMemoryCache cache, ILogger<ExecutiveDashboardService> log)
    {
        _repo = repo;
        _cache = cache;
        _log = log;
    }

    private static string KeyFor(FilterContext f) =>
        $"exec::{f.DateFrom:yyyyMMdd}::{f.DateTo:yyyyMMdd}::{f.BranchCsv ?? "ALL"}";

    public async Task<ExecutiveDashboardViewModel> BuildAsync(
        FilterContext filter, bool forceRefresh, CancellationToken ct = default)
    {
        var key = KeyFor(filter);

        if (forceRefresh)
            _cache.Remove(key);

        if (_cache.TryGetValue(key, out ExecutiveDashboardViewModel? cached) && cached is not null)
            return cached;

        var sw = System.Diagnostics.Stopwatch.StartNew();

        // Each call opens its own connection, so these run concurrently.
        var summaryTask = _repo.GetExecSummaryAsync(filter, ct);
        var trendTask = _repo.GetSalesTrendAsync(filter, 13, ct);
        var branchTask = _repo.GetBranchScorecardAsync(filter, ct);
        var flowTask = _repo.GetFlowBarAsync(filter, ct);
        var listTask = _repo.GetBranchesAsync(ct);

        await Task.WhenAll(summaryTask, trendTask, branchTask, flowTask, listTask);

        var vm = new ExecutiveDashboardViewModel
        {
            Filter = filter,
            Summary = await summaryTask,
            Trend = await trendTask,
            Branches = await branchTask,
            Flow = await flowTask,
            AllBranches = await listTask,
            GeneratedAt = DateTime.Now
        };

        sw.Stop();
        _log.LogInformation("Executive dashboard built in {Ms} ms for {Key}",
            sw.ElapsedMilliseconds, key);

        _cache.Set(key, vm, CacheWindow);
        return vm;
    }
}
