using CoreReporting.Data;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace CoreReporting.Controllers;

/// <summary>
/// Exception Center: business-process red flags, distinct from Dashboard's
/// Health Check (which verifies ledger math ties out). Management + Audit
/// only, per the brief — deliberately NOT Accounting, unlike every other
/// module in this app. sp_rpt_ExceptionCenter_Summary/_Detail have no
/// @BranchCodes parameter at all (see sql/15-exception-center.sql), so like
/// SalesController this controller never populates ViewBag.Branches — the
/// shared top-bar branch chip in _Layout.cshtml stays hidden here.
/// </summary>
[Authorize(Roles = "Executive,Audit")]
public sealed class ExceptionCenterController : FilterAwareController
{
    private readonly ExceptionCenterService _svc;
    private readonly IReportRepository _repo;

    public ExceptionCenterController(ExceptionCenterService svc, IReportRepository repo)
    {
        _svc = svc;
        _repo = repo;
    }

    public async Task<IActionResult> Index(CancellationToken ct)
    {
        var vm = await _svc.BuildAsync(CurrentFilter, forceRefresh: false, ct);

        // So the shared top-bar filter form (see _Layout.cshtml) renders the
        // actual applied period on this page too. ViewBag.Branches is
        // deliberately NOT set — this module has no branch dimension.
        ViewBag.Filter = vm.Filter;

        return View(vm);
    }

    /// <summary>
    /// Polled by the browser every five minutes and by the Refresh button.
    /// Same shape/spirit as the other modules' *Data actions.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> IndexData(bool force = false, CancellationToken ct = default)
    {
        var vm = await _svc.BuildAsync(CurrentFilter, force, ct);

        return Json(new
        {
            generatedAt = vm.GeneratedAt.ToString("HH:mm"),
            dateFrom = vm.Filter.DateFrom.ToString("yyyy-MM-dd"),
            dateTo = vm.Filter.DateTo.ToString("yyyy-MM-dd"),
            rows = vm.Rows
        });
    }

    /// <summary>
    /// Drill-down behind one Exception Center card, via
    /// dbo.sp_rpt_ExceptionCenter_Detail. DateFrom/DateTo come from the same
    /// session filter Index already uses, not separate query parameters, so
    /// the drill-down always matches the period the summary card was
    /// computed over. Returns the same generic { procName, renderStyle,
    /// generatedAt, resultSets: [{ columns, rows }] } shape as
    /// DashboardController.HealthCheckDetail / ReportCenterController.RunReport,
    /// so the frontend can reuse the same generic grid renderer.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> Detail(string code, CancellationToken ct)
    {
        var f = CurrentFilter;

        try
        {
            var result = await _repo.GetExceptionCenterDetailAsync(code, f.DateFrom, f.DateTo, ct);
            return Json(new
            {
                procName = result.ProcName,
                renderStyle = result.RenderStyle.ToString(),
                generatedAt = result.GeneratedAt.ToString("yyyy-MM-dd HH:mm"),
                resultSets = result.ResultSets.Select(rs => new
                {
                    columns = rs.Columns.Select(c => new { name = c.Name, type = c.Type.ToString() }),
                    rows = rs.Rows,
                    totalRowCount = rs.TotalRowCount
                })
            });
        }
        catch (SqlException ex)
        {
            // sp_rpt_ExceptionCenter_Detail RAISERRORs for an unrecognized
            // @ExceptionCode instead of returning an empty result — surface
            // that as a 400 with a clear message, not an unhandled 500.
            return BadRequest($"Invalid exception detail request (code={code}): {ex.Message}");
        }
    }
}
