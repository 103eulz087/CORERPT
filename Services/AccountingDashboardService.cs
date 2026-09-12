using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.Extensions.Caching.Memory;

namespace CoreReporting.Services;

/// <summary>
/// Assembles the Finance Overview dashboard (AR/AP aging) and caches it
/// briefly, mirroring ExecutiveDashboardService.
///
/// AR aging is branch-filtered (Customers.BranchCode); AP aging (both trade
/// and expense) is company-wide by design (neither APAccounts nor
/// ExpenseSummary has branch attribution). Because of that, AR, AP-Trade and
/// AP-Expense are cached under SEPARATE keys rather than one combined key:
/// AR's key includes the branch filter; AP-Trade's and AP-Expense's keys are
/// AsOfDate only (and are themselves distinct from each other, so adding
/// AP-Expense could not collide with or invalidate the existing AP-Trade
/// entry). That way switching the branch filter only invalidates the AR half
/// — AP-Trade/AP-Expense would return the exact same rows regardless of
/// branch, so there is no reason to recompute or evict them on a branch-only
/// change, and no risk of one book's cache entry accidentally being reused
/// for another.
/// </summary>
public sealed class AccountingDashboardService
{
    private readonly IReportRepository _repo;
    private readonly IMemoryCache _cache;
    private readonly ILogger<AccountingDashboardService> _log;

    private static readonly TimeSpan CacheWindow = TimeSpan.FromMinutes(2);

    /// <summary>
    /// Daily branch activity gets a much shorter cache window than the aging
    /// data. The whole point of this widget is watching today's invoices
    /// accumulate through the day; a 2-minute window (fine for AR/AP, which
    /// only move end-of-day) would make the widget feel stale against the
    /// 5-minute poll it rides alongside. 60 seconds means every poll (and
    /// every manual refresh) is effectively always a fresh read, while still
    /// giving the DB a floor against back-to-back requests if a user mashes
    /// the refresh button.
    /// </summary>
    private static readonly TimeSpan DailyActivityCacheWindow = TimeSpan.FromSeconds(60);

    public AccountingDashboardService(
        IReportRepository repo, IMemoryCache cache, ILogger<AccountingDashboardService> log)
    {
        _repo = repo;
        _cache = cache;
        _log = log;
    }

    private static string ArKeyFor(FilterContext f) =>
        $"acct::ar::{f.DateTo:yyyyMMdd}::{f.BranchCsv ?? "ALL"}";

    private static string ApKeyFor(DateOnly asOfDate) =>
        $"acct::ap::{asOfDate:yyyyMMdd}";

    private static string ApExpKeyFor(DateOnly asOfDate) =>
        $"acct::apexp::{asOfDate:yyyyMMdd}";

    /// <summary>Keyed on today's calendar date (not the dashboard's period
    /// filter — this widget always shows "today" regardless of Filter.DateTo)
    /// so the short-lived cache entry naturally rolls over at midnight instead
    /// of ever serving yesterday's snapshot into a new day.</summary>
    private static string DailyActivityKeyFor() =>
        $"acct::dailyactivity::{DateOnly.FromDateTime(DateTime.Now):yyyyMMdd}";

    public async Task<FinanceOverviewViewModel> BuildAsync(
        FilterContext filter, bool forceRefresh, CancellationToken ct = default)
    {
        var arKey = ArKeyFor(filter);
        var apKey = ApKeyFor(filter.DateTo);
        var apExpKey = ApExpKeyFor(filter.DateTo);
        var dailyActivityKey = DailyActivityKeyFor();

        if (forceRefresh)
        {
            _cache.Remove(arKey);
            _cache.Remove(apKey);
            _cache.Remove(apExpKey);
            _cache.Remove(dailyActivityKey);
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();

        var haveAr = _cache.TryGetValue(arKey, out ArAgingResult? cachedAr) && cachedAr is not null;
        var haveAp = _cache.TryGetValue(apKey, out ApAgingResult? cachedAp) && cachedAp is not null;
        var haveApExp = _cache.TryGetValue(apExpKey, out ApExpAgingResult? cachedApExp) && cachedApExp is not null;
        var haveDailyActivity = _cache.TryGetValue(dailyActivityKey, out DailyBranchActivityResult? cachedDailyActivity)
            && cachedDailyActivity is not null;

        // Each call opens its own connection, so the misses run concurrently.
        Task<ArAgingResult>? arTask = haveAr ? null : _repo.GetArAgingAsync(filter, ct);
        Task<ApAgingResult>? apTask = haveAp ? null : _repo.GetApAgingAsync(filter.DateTo, ct);
        Task<ApExpAgingResult>? apExpTask = haveApExp ? null : _repo.GetApExpAgingAsync(filter.DateTo, ct);
        // forDate: null — let the proc default @ForDate to today itself.
        Task<DailyBranchActivityResult>? dailyActivityTask =
            haveDailyActivity ? null : _repo.GetDailyBranchActivityAsync(forDate: null, ct);
        var branchesTask = _repo.GetBranchesAsync(ct);

        var pending = new List<Task> { branchesTask };
        if (arTask is not null) pending.Add(arTask);
        if (apTask is not null) pending.Add(apTask);
        if (apExpTask is not null) pending.Add(apExpTask);
        if (dailyActivityTask is not null) pending.Add(dailyActivityTask);
        await Task.WhenAll(pending);

        var ar = haveAr ? cachedAr! : await arTask!;
        var ap = haveAp ? cachedAp! : await apTask!;
        var apExp = haveApExp ? cachedApExp! : await apExpTask!;
        var dailyActivity = haveDailyActivity ? cachedDailyActivity! : await dailyActivityTask!;
        var branches = await branchesTask;

        if (!haveAr) _cache.Set(arKey, ar, CacheWindow);
        if (!haveAp) _cache.Set(apKey, ap, CacheWindow);
        if (!haveApExp) _cache.Set(apExpKey, apExp, CacheWindow);
        if (!haveDailyActivity) _cache.Set(dailyActivityKey, dailyActivity, DailyActivityCacheWindow);

        var vm = new FinanceOverviewViewModel
        {
            Filter = filter,
            AllBranches = branches,
            Ar = ar,
            Ap = ap,
            ApExp = apExp,
            DailyActivity = dailyActivity,
            GeneratedAt = DateTime.Now
        };

        sw.Stop();
        _log.LogInformation(
            "Finance Overview built in {Ms} ms (AR key {ArKey}, AP key {ApKey}, ApExp key {ApExpKey}, " +
            "DailyActivity key {DailyActivityKey}, arHit={ArHit}, apHit={ApHit}, apExpHit={ApExpHit}, " +
            "dailyActivityHit={DailyActivityHit})",
            sw.ElapsedMilliseconds, arKey, apKey, apExpKey, dailyActivityKey, haveAr, haveAp, haveApExp,
            haveDailyActivity);

        return vm;
    }
}
