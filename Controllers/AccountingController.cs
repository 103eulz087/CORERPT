using ClosedXML.Excel;
using CoreReporting.Data;
using CoreReporting.Models;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CoreReporting.Controllers;

/// <summary>
/// Part A of the Accounting module: the Finance Overview dashboard
/// (AR/AP aging, DSO). Mirrors DashboardController's Executive actions.
/// </summary>
[Authorize(Roles = "Accounting,Audit,Executive")]
public sealed class AccountingController : FilterAwareController
{
    private readonly AccountingDashboardService _svc;
    private readonly IReportRepository _repo;

    public AccountingController(AccountingDashboardService svc, IReportRepository repo)
    {
        _svc = svc;
        _repo = repo;
    }

    public async Task<IActionResult> FinanceOverview(CancellationToken ct)
    {
        var vm = await _svc.BuildAsync(CurrentFilter, forceRefresh: false, ct);

        // So the shared top-bar filter form (see _Layout.cshtml) renders the
        // actual applied period/branch on this page too, not just on the
        // Executive dashboard's own view model.
        ViewBag.Filter = vm.Filter;
        ViewBag.Branches = vm.AllBranches;

        return View(vm);
    }

    /// <summary>
    /// Polled by the browser every five minutes and by the Refresh button.
    /// Same shape/spirit as DashboardController.ExecutiveData: only the
    /// figures, so a poll costs one small JSON payload.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> FinanceOverviewData(bool force = false, CancellationToken ct = default)
    {
        var vm = await _svc.BuildAsync(CurrentFilter, force, ct);

        return Json(new
        {
            generatedAt = vm.GeneratedAt.ToString("HH:mm"),
            asOfDate = vm.AsOfDate.ToString("yyyy-MM-dd"),
            arCustomers = vm.Ar.Customers,
            arBranchTotals = vm.Ar.BranchTotals,
            arDso = vm.Ar.Dso,
            apSuppliers = vm.Ap.Suppliers,
            apCompanyTotal = vm.Ap.CompanyTotal,
            apExpSuppliers = vm.ApExp.Suppliers,
            apExpCompanyTotal = vm.ApExp.CompanyTotal,
            dailyBranches = vm.DailyActivity.Branches,
            dailyCompanyTotal = vm.DailyActivity.CompanyTotal
        });
    }

    /// <summary>AR aging grid to Excel. Customer/branch codes stay text so
    /// leading zeros survive.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportArAging(CancellationToken ct)
    {
        var f = CurrentFilter;
        var ar = await _repo.GetArAgingAsync(f, ct);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("AR Aging");

        ws.Cell(1, 1).Value = "AR Aging";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Value = $"As of: {f.DateTo:yyyy-MM-dd}";
        ws.Cell(3, 1).Value = $"Generated: {DateTime.Now:yyyy-MM-dd HH:mm}";

        var headers = new[]
        {
            "Customer Code", "Customer Name", "Branch", "Current", "1-30 Days",
            "31-60 Days", "61-90 Days", "90+ Days", "Total Outstanding",
            "Credit Limit", "Term (days)", "Exposure %", "Oldest Age (days)"
        };
        for (var c = 0; c < headers.Length; c++)
        {
            ws.Cell(5, c + 1).Value = headers[c];
            ws.Cell(5, c + 1).Style.Font.Bold = true;
        }

        var r = 6;
        foreach (var row in ar.Customers)
        {
            ws.Cell(r, 1).SetValue(row.CustomerKey).Style.NumberFormat.Format = "@";
            ws.Cell(r, 2).Value = row.CustomerName;
            ws.Cell(r, 3).SetValue(row.BranchCode).Style.NumberFormat.Format = "@";
            ws.Cell(r, 4).Value = row.CurrentAmount;
            ws.Cell(r, 5).Value = row.PastDue1To30;
            ws.Cell(r, 6).Value = row.PastDue31To60;
            ws.Cell(r, 7).Value = row.PastDue61To90;
            ws.Cell(r, 8).Value = row.PastDue90Plus;
            ws.Cell(r, 9).Value = row.TotalOutstanding;
            if (row.CreditLimit.HasValue) ws.Cell(r, 10).Value = row.CreditLimit.Value;
            if (row.Term.HasValue) ws.Cell(r, 11).Value = row.Term.Value;
            if (row.ExposurePct.HasValue) ws.Cell(r, 12).Value = row.ExposurePct.Value;
            ws.Cell(r, 13).Value = row.OldestAgeDays;
            r++;
        }

        var lastRow = Math.Max(6, r - 1);
        ws.Range(6, 4, lastRow, 10).Style.NumberFormat.Format = "#,##0.00";
        ws.Range(6, 12, lastRow, 12).Style.NumberFormat.Format = "0.0\"%\"";
        ws.Columns().AdjustToContents();

        using var ms = new MemoryStream();
        wb.SaveAs(ms);

        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"ArAging_{f.DateTo:yyyyMMdd}.xlsx");
    }

    /// <summary>AP aging grid to Excel. Supplier codes stay text so leading
    /// zeros survive.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportApAging(CancellationToken ct)
    {
        var f = CurrentFilter;
        var ap = await _repo.GetApAgingAsync(f.DateTo, ct);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("AP Aging");

        ws.Cell(1, 1).Value = "AP Aging";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Value = $"As of: {f.DateTo:yyyy-MM-dd}";
        ws.Cell(3, 1).Value = $"Generated: {DateTime.Now:yyyy-MM-dd HH:mm}";

        var headers = new[]
        {
            "Supplier ID", "Supplier Name", "Current", "1-30 Days",
            "31-60 Days", "61-90 Days", "90+ Days", "Total Outstanding", "Oldest Age (days)"
        };
        for (var c = 0; c < headers.Length; c++)
        {
            ws.Cell(5, c + 1).Value = headers[c];
            ws.Cell(5, c + 1).Style.Font.Bold = true;
        }

        var r = 6;
        foreach (var row in ap.Suppliers)
        {
            ws.Cell(r, 1).SetValue(row.SupplierId).Style.NumberFormat.Format = "@";
            ws.Cell(r, 2).Value = row.SupplierName;
            ws.Cell(r, 3).Value = row.CurrentAmount;
            ws.Cell(r, 4).Value = row.PastDue1To30;
            ws.Cell(r, 5).Value = row.PastDue31To60;
            ws.Cell(r, 6).Value = row.PastDue61To90;
            ws.Cell(r, 7).Value = row.PastDue90Plus;
            ws.Cell(r, 8).Value = row.TotalOutstanding;
            ws.Cell(r, 9).Value = row.OldestAgeDays;
            r++;
        }

        var lastRow = Math.Max(6, r - 1);
        ws.Range(6, 3, lastRow, 8).Style.NumberFormat.Format = "#,##0.00";
        ws.Columns().AdjustToContents();

        using var ms = new MemoryStream();
        wb.SaveAs(ms);

        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"ApAging_{f.DateTo:yyyyMMdd}.xlsx");
    }

    /// <summary>AP-Expense (non-trade payables, ExpenseSummary) aging grid to
    /// Excel. Supplier codes stay text so leading zeros survive.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportApExpAging(CancellationToken ct)
    {
        var f = CurrentFilter;
        var apExp = await _repo.GetApExpAgingAsync(f.DateTo, ct);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("AP-Expense Aging");

        ws.Cell(1, 1).Value = "AP-Expense Aging";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Value = $"As of: {f.DateTo:yyyy-MM-dd}";
        ws.Cell(3, 1).Value = $"Generated: {DateTime.Now:yyyy-MM-dd HH:mm}";

        var headers = new[]
        {
            "Supplier ID", "Supplier Name", "Current", "1-30 Days",
            "31-60 Days", "61-90 Days", "90+ Days", "Total Outstanding", "Oldest Age (days)"
        };
        for (var c = 0; c < headers.Length; c++)
        {
            ws.Cell(5, c + 1).Value = headers[c];
            ws.Cell(5, c + 1).Style.Font.Bold = true;
        }

        var r = 6;
        foreach (var row in apExp.Suppliers)
        {
            ws.Cell(r, 1).SetValue(row.SupplierId).Style.NumberFormat.Format = "@";
            ws.Cell(r, 2).Value = row.SupplierName;
            ws.Cell(r, 3).Value = row.CurrentAmount;
            ws.Cell(r, 4).Value = row.PastDue1To30;
            ws.Cell(r, 5).Value = row.PastDue31To60;
            ws.Cell(r, 6).Value = row.PastDue61To90;
            ws.Cell(r, 7).Value = row.PastDue90Plus;
            ws.Cell(r, 8).Value = row.TotalOutstanding;
            ws.Cell(r, 9).Value = row.OldestAgeDays;
            r++;
        }

        var lastRow = Math.Max(6, r - 1);
        ws.Range(6, 3, lastRow, 8).Style.NumberFormat.Format = "#,##0.00";
        ws.Columns().AdjustToContents();

        using var ms = new MemoryStream();
        wb.SaveAs(ms);

        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"ApExpAging_{f.DateTo:yyyyMMdd}.xlsx");
    }
}
