using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.Extensions.Caching.Memory;

namespace CoreReporting.Services;

/// <summary>
/// Assembles the Exception Center landing page and caches it briefly,
/// mirroring AccountingDashboardService/SalesDashboardService. This is a
/// cross-cutting/Audit module (Management + Audit only, see
/// ExceptionCenterController), not owned by any one department dashboard, so
/// it gets its own service rather than being bolted onto an existing one.
/// sp_rpt_ExceptionCenter_Summary has no branch dimension at all (see
/// sql/15-exception-center.sql), so the cache key is Period only, never
/// Branch — same reasoning as SalesDashboardService.
/// </summary>
public sealed class ExceptionCenterService
{
    private readonly IReportRepository _repo;
    private readonly IMemoryCache _cache;
    private readonly ILogger<ExceptionCenterService> _log;

    private static readonly TimeSpan CacheWindow = TimeSpan.FromMinutes(2);

    public ExceptionCenterService(
        IReportRepository repo, IMemoryCache cache, ILogger<ExceptionCenterService> log)
    {
        _repo = repo;
        _cache = cache;
        _log = log;
    }

    private static string KeyFor(FilterContext f) =>
        $"exceptioncenter::summary::{f.DateFrom:yyyyMMdd}::{f.DateTo:yyyyMMdd}";

    public async Task<ExceptionCenterViewModel> BuildAsync(
        FilterContext filter, bool forceRefresh, CancellationToken ct = default)
    {
        var key = KeyFor(filter);

        if (forceRefresh) _cache.Remove(key);

        var sw = System.Diagnostics.Stopwatch.StartNew();

        var haveRows = _cache.TryGetValue(key, out IReadOnlyList<ExceptionSummaryRow>? cachedRows)
            && cachedRows is not null;

        var rows = haveRows
            ? cachedRows!
            : await _repo.GetExceptionCenterSummaryAsync(filter.DateFrom, filter.DateTo, ct);

        if (!haveRows) _cache.Set(key, rows, CacheWindow);

        var vm = new ExceptionCenterViewModel
        {
            Filter = filter,
            Rows = rows,
            GeneratedAt = DateTime.Now
        };

        sw.Stop();
        _log.LogInformation(
            "Exception Center summary built in {Ms} ms (key {Key}, hit={Hit})",
            sw.ElapsedMilliseconds, key, haveRows);

        return vm;
    }
}
