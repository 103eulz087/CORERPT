using CoreReporting.Data;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace CoreReporting.Controllers;

/// <summary>
/// Item Costing Recon: is the unit cost stock is carried at the same as what
/// its linked expense invoices (freight, handling, brokerage, duties)
/// justify? See docs/ItemCostingRecon_WebReporting_Handoff.md for the full
/// business meaning.
///
/// Deliberately does NOT inherit FilterAwareController — this module has its
/// own date-range + shipment-number filter, not the shared session
/// Period/Branch filter, because the underlying proc has no branch-code
/// parameter at all (only a BranchName string in its output). This mirrors
/// how ReportCenterController also does not inherit it, per this codebase's
/// documented architecture split (see CLAUDE.md).
/// </summary>
[Authorize(Roles = "Executive,Accounting,Audit")]
public sealed class ItemCostingReconController : Controller
{
    private readonly ItemCostingReconService _svc;
    private readonly IReportRepository _repo;

    public ItemCostingReconController(ItemCostingReconService svc, IReportRepository repo)
    {
        _svc = svc;
        _repo = repo;
    }

    /// <summary>
    /// When dateFrom/dateTo are omitted, defaults to the start of last month
    /// through today — matching the ERP form's own default (handoff doc §5).
    /// </summary>
    public async Task<IActionResult> Index(
        DateOnly? dateFrom, DateOnly? dateTo, string? shipmentNo, bool force, CancellationToken ct)
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        var from = dateFrom ?? new DateOnly(today.Year, today.Month, 1).AddMonths(-1);
        var to = dateTo ?? today;

        var vm = await _svc.BuildAsync(from, to, shipmentNo, force, ct);

        return View(vm);
    }

    /// <summary>
    /// Drill-down behind one linked-expense row, via
    /// dbo.sp_rpt_ItemCostingRecon_ExpenseTickets. Returns the same generic
    /// { procName, renderStyle, generatedAt, resultSets: [{ columns, rows }] }
    /// shape as DashboardController.HealthCheckDetail /
    /// ExceptionCenterController.Detail, so the frontend can reuse the same
    /// generic drilldown modal (drilldown-modal.js).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> TicketsDrilldown(
        string referenceNumber, string invoiceNo, string shipmentNo, CancellationToken ct)
    {
        try
        {
            var result = await _repo.GetItemCostingReconTicketsAsync(referenceNumber, invoiceNo, shipmentNo, ct);
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
            // Not documented as RAISERROR-ing on bad input the way the health
            // check drill-down is — this catch is defensive consistency with
            // the other generic drill-down endpoints, not a known requirement.
            return BadRequest(
                $"Invalid tickets drill-down request (ref={referenceNumber}, invoice={invoiceNo}, shipment={shipmentNo}): {ex.Message}");
        }
    }
}
