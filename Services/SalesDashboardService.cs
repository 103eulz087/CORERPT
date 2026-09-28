using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.Extensions.Caching.Memory;

namespace CoreReporting.Services;

/// <summary>
/// Assembles the Agent Scorecard dashboard and caches it briefly, mirroring
/// AccountingDashboardService. sp_rpt_Agent_Scorecard has no branch
/// parameter at all (a sales agent's book is not confined to one branch —
/// see sql/14-agent-scorecard.sql's header), so the cache key is Period only,
/// never Branch.
/// </summary>
public sealed class SalesDashboardService
{
    private readonly IReportRepository _repo;
    private readonly IMemoryCache _cache;
    private readonly ILogger<SalesDashboardService> _log;

    private static readonly TimeSpan CacheWindow = TimeSpan.FromMinutes(2);

    public SalesDashboardService(
        IReportRepository repo, IMemoryCache cache, ILogger<SalesDashboardService> log)
    {
        _repo = repo;
        _cache = cache;
        _log = log;
    }

    private static string KeyFor(FilterContext f) =>
        $"sales::agentscorecard::{f.DateFrom:yyyyMMdd}::{f.DateTo:yyyyMMdd}";

    public async Task<AgentScorecardViewModel> BuildAsync(
        FilterContext filter, bool forceRefresh, CancellationToken ct = default)
    {
        var key = KeyFor(filter);

        if (forceRefresh) _cache.Remove(key);

        var sw = System.Diagnostics.Stopwatch.StartNew();

        var haveRows = _cache.TryGetValue(key, out IReadOnlyList<AgentScorecardRow>? cachedRows)
            && cachedRows is not null;

        var rows = haveRows
            ? cachedRows!
            : await _repo.GetAgentScorecardAsync(filter.DateFrom, filter.DateTo, agentNamesCsv: null, ct);

        if (!haveRows) _cache.Set(key, rows, CacheWindow);

        var vm = new AgentScorecardViewModel
        {
            Filter = filter,
            Rows = rows,
            GeneratedAt = DateTime.Now
        };

        sw.Stop();
        _log.LogInformation(
            "Agent Scorecard built in {Ms} ms (key {Key}, hit={Hit})",
            sw.ElapsedMilliseconds, key, haveRows);

        return vm;
    }
}
