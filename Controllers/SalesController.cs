using ClosedXML.Excel;
using CoreReporting.Models;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CoreReporting.Controllers;

/// <summary>
/// Sales module: the Agent Scorecard dashboard. v1 is management-only — this
/// app has no per-agent login (DevAuth only knows Executive/Accounting/Audit
/// department roles), so there is no per-agent self-filtering here.
/// sp_rpt_Agent_Scorecard has no branch parameter at all (a sales agent's
/// book is not confined to one branch), so unlike AccountingController this
/// controller never populates ViewBag.Branches — the shared top-bar branch
/// chip in _Layout.cshtml stays hidden on this page as a result.
/// </summary>
[Authorize(Roles = "Executive,Accounting,Audit")]
public sealed class SalesController : FilterAwareController
{
    private readonly SalesDashboardService _svc;

    public SalesController(SalesDashboardService svc)
    {
        _svc = svc;
    }

    public async Task<IActionResult> AgentScorecard(CancellationToken ct)
    {
        var vm = await _svc.BuildAsync(CurrentFilter, forceRefresh: false, ct);

        // So the shared top-bar filter form (see _Layout.cshtml) renders the
        // actual applied period on this page too. ViewBag.Branches is
        // deliberately NOT set — this proc has no branch dimension, so the
        // branch chip must stay hidden (_Layout.cshtml only renders it when
        // branches.Count > 0).
        ViewBag.Filter = vm.Filter;

        return View(vm);
    }

    /// <summary>
    /// Polled by the browser every five minutes and by the Refresh button.
    /// Same shape/spirit as AccountingController.FinanceOverviewData.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> AgentScorecardData(bool force = false, CancellationToken ct = default)
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

    /// <summary>Agent Scorecard grid to Excel. Agent labels stay text so
    /// nothing gets auto-reformatted (e.g. a name ClosedXML might otherwise
    /// try to coerce).</summary>
    [HttpGet]
    public async Task<IActionResult> ExportAgentScorecard(CancellationToken ct)
    {
        var f = CurrentFilter;
        var vm = await _svc.BuildAsync(f, forceRefresh: false, ct);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("Agent Scorecard");

        ws.Cell(1, 1).Value = "Agent Scorecard";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Value = $"Period: {f.DateFrom:yyyy-MM-dd} to {f.DateTo:yyyy-MM-dd}";
        ws.Cell(3, 1).Value = $"Generated: {DateTime.Now:yyyy-MM-dd HH:mm}";

        var headers = new[]
        {
            "Agent", "Row Type", "Net Sales", "Net Sales (Prior)", "Net Sales Δ%",
            "Total Assigned", "Active", "Dormant", "New Accounts",
            "AR Outstanding", "AR Past Due 31+", "AR Past Due %",
            "Oldest Open Item (days)", "Net Sales (90-Day)", "DSO"
        };
        for (var c = 0; c < headers.Length; c++)
        {
            ws.Cell(5, c + 1).Value = headers[c];
            ws.Cell(5, c + 1).Style.Font.Bold = true;
        }

        var r = 6;
        foreach (var row in vm.Rows)
        {
            ws.Cell(r, 1).SetValue(row.AgentLabel).Style.NumberFormat.Format = "@";
            ws.Cell(r, 2).SetValue(row.RowType).Style.NumberFormat.Format = "@";
            ws.Cell(r, 3).Value = row.NetSales;
            ws.Cell(r, 4).Value = row.NetSalesPrior;
            if (row.NetSalesDeltaPct.HasValue) ws.Cell(r, 5).Value = row.NetSalesDeltaPct.Value;
            ws.Cell(r, 6).Value = row.TotalAssignedAccounts;
            ws.Cell(r, 7).Value = row.ActiveAccounts;
            ws.Cell(r, 8).Value = row.DormantAccounts;
            ws.Cell(r, 9).Value = row.NewAccounts;
            ws.Cell(r, 10).Value = row.AROutstanding;
            ws.Cell(r, 11).Value = row.ARPastDue31Plus;
            if (row.ARPastDuePct.HasValue) ws.Cell(r, 12).Value = row.ARPastDuePct.Value;
            if (row.OldestOpenItemAgeDays.HasValue) ws.Cell(r, 13).Value = row.OldestOpenItemAgeDays.Value;
            ws.Cell(r, 14).Value = row.NetSales90Day;
            if (row.DSO.HasValue) ws.Cell(r, 15).Value = row.DSO.Value;
            r++;
        }

        var lastRow = Math.Max(6, r - 1);
        ws.Range(6, 3, lastRow, 4).Style.NumberFormat.Format = "#,##0.00";
        ws.Range(6, 5, lastRow, 5).Style.NumberFormat.Format = "0.0\"%\"";
        ws.Range(6, 10, lastRow, 11).Style.NumberFormat.Format = "#,##0.00";
        ws.Range(6, 12, lastRow, 12).Style.NumberFormat.Format = "0.00\"%\"";
        ws.Range(6, 14, lastRow, 14).Style.NumberFormat.Format = "#,##0.00";
        ws.Range(6, 15, lastRow, 15).Style.NumberFormat.Format = "0.0";
        ws.Columns().AdjustToContents();

        using var ms = new MemoryStream();
        wb.SaveAs(ms);

        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"AgentScorecard_{f.DateFrom:yyyyMMdd}_{f.DateTo:yyyyMMdd}.xlsx");
    }
}
