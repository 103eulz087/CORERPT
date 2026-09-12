using System.Security.Claims;
using ClosedXML.Excel;
using CoreReporting.Data;
using CoreReporting.Models;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace CoreReporting.Controllers;

[Authorize]
public sealed class DashboardController : FilterAwareController
{
    private readonly ExecutiveDashboardService _exec;
    private readonly IReportRepository _repo;

    public DashboardController(ExecutiveDashboardService exec, IReportRepository repo)
    {
        _exec = exec;
        _repo = repo;
    }

    /* ------------------------------------------------------------------
       The filter lives in session (CurrentFilter, from FilterAwareController)
       so Period and Branch survive navigation. That persistence is what
       makes this a portal rather than a pile of separate reports.
    ------------------------------------------------------------------ */

    [Authorize(Roles = "Executive,Accounting,Audit")]
    public async Task<IActionResult> Executive(CancellationToken ct)
    {
        var vm = await _exec.BuildAsync(CurrentFilter, forceRefresh: false, ct);
        return View(vm);
    }

    /// <summary>Applies the top-bar filter and returns to the caller's page.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult ApplyFilter(DateOnly dateFrom, DateOnly dateTo,
                                     string[]? branchCodes, string? returnUrl)
    {
        if (dateTo < dateFrom) (dateFrom, dateTo) = (dateTo, dateFrom);

        CurrentFilter = new FilterContext
        {
            DateFrom = dateFrom,
            DateTo = dateTo,
            // Branch codes stay strings. No parsing, no int conversion.
            BranchCodes = branchCodes?.Where(c => !string.IsNullOrWhiteSpace(c))
                                      .Select(c => c.Trim())
                                      .ToList() ?? new List<string>()
        };

        if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
            return Redirect(returnUrl);

        return RedirectToAction(nameof(Executive));
    }

    /// <summary>
    /// Polled by the browser every five minutes and by the Refresh button.
    /// Returns only the figures, so a poll costs one small JSON payload
    /// instead of a full page render.
    /// </summary>
    [HttpGet]
    [Authorize(Roles = "Executive,Accounting,Audit")]
    public async Task<IActionResult> ExecutiveData(bool force = false, CancellationToken ct = default)
    {
        var vm = await _exec.BuildAsync(CurrentFilter, force, ct);

        return Json(new
        {
            generatedAt = vm.GeneratedAt.ToString("HH:mm"),
            summary = vm.Summary,
            trend = vm.Trend,
            branches = vm.Branches,
            flow = vm.Flow
        });
    }

    /// <summary>Branch scorecard to Excel. Server side, no viewer control.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportBranchScorecard(CancellationToken ct)
    {
        var f = CurrentFilter;
        var rows = await _repo.GetBranchScorecardAsync(f, ct);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("Branch Scorecard");

        ws.Cell(1, 1).Value = "Branch Scorecard";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Value = $"Period: {f.PeriodLabel}";
        ws.Cell(3, 1).Value = $"Generated: {DateTime.Now:yyyy-MM-dd HH:mm}";

        var headers = new[]
        {
            "Branch Code", "Branch Name", "Net Sales", "COGS", "Gross Profit",
            "Gross Margin %", "Operating Expense", "Receivables", "Inventory", "Payables"
        };
        for (var c = 0; c < headers.Length; c++)
        {
            ws.Cell(5, c + 1).Value = headers[c];
            ws.Cell(5, c + 1).Style.Font.Bold = true;
        }

        var r = 6;
        foreach (var row in rows)
        {
            // Written as text so Excel keeps the leading zeros on '001'.
            ws.Cell(r, 1).SetValue(row.BranchCode).Style.NumberFormat.Format = "@";
            ws.Cell(r, 2).Value = row.BranchName;
            ws.Cell(r, 3).Value = row.NetSales;
            ws.Cell(r, 4).Value = row.Cogs;
            ws.Cell(r, 5).Value = row.GrossProfit;
            ws.Cell(r, 6).Value = row.GrossMarginPct;
            ws.Cell(r, 7).Value = row.OperatingExpense;
            ws.Cell(r, 8).Value = row.Receivables;
            ws.Cell(r, 9).Value = row.Inventory;
            ws.Cell(r, 10).Value = row.Payables;
            r++;
        }

        ws.Range(6, 3, Math.Max(6, r - 1), 5).Style.NumberFormat.Format = "#,##0.00";
        ws.Range(6, 7, Math.Max(6, r - 1), 10).Style.NumberFormat.Format = "#,##0.00";
        ws.Range(6, 6, Math.Max(6, r - 1), 6).Style.NumberFormat.Format = "0.0\"%\"";
        ws.Columns().AdjustToContents();

        using var ms = new MemoryStream();
        wb.SaveAs(ms);

        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"BranchScorecard_{f.DateFrom:yyyyMMdd}_{f.DateTo:yyyyMMdd}.xlsx");
    }

    /// <summary>
    /// The health check, surfaced in the app. This is the first widget of
    /// the future Audit board and the reason anyone can trust the numbers
    /// above it.
    /// </summary>
    [Authorize(Roles = "Accounting,Audit,Executive")]
    public async Task<IActionResult> Health(CancellationToken ct)
    {
        var f = CurrentFilter;
        var items = await _repo.GetHealthCheckAsync(f.DateFrom, f.DateTo, ct);
        ViewBag.Filter = f;
        return View(items);
    }

    /// <summary>
    /// Drill-down behind one Health Check row: the offending rows for one
    /// Seq (1-15) of sp_rpt_DataHealthCheck, via
    /// dbo.sp_rpt_DataHealthCheckDetail. DateFrom/DateTo come from the same
    /// session filter Health already uses, not separate query parameters, so
    /// the drill-down always matches the period the summary row was computed
    /// over. AsOfDate is left null; the proc defaults it to @DateTo itself.
    /// Returns the same generic { procName, renderStyle, generatedAt,
    /// resultSets: [{ columns, rows }] } shape as ReportCenterController's
    /// RunReport, so the frontend can reuse the same generic grid renderer.
    /// </summary>
    [HttpGet]
    [Authorize(Roles = "Accounting,Audit,Executive")]
    public async Task<IActionResult> HealthCheckDetail(int seq, CancellationToken ct)
    {
        var f = CurrentFilter;

        try
        {
            var result = await _repo.GetHealthCheckDetailAsync(seq, f.DateFrom, f.DateTo, asOfDate: null, ct);
            return Json(new
            {
                procName = result.ProcName,
                renderStyle = result.RenderStyle.ToString(),
                generatedAt = result.GeneratedAt.ToString("yyyy-MM-dd HH:mm"),
                resultSets = result.ResultSets.Select(rs => new
                {
                    columns = rs.Columns.Select(c => new { name = c.Name, type = c.Type.ToString() }),
                    rows = rs.Rows
                })
            });
        }
        catch (SqlException ex)
        {
            // sp_rpt_DataHealthCheckDetail RAISERROR/THROWs for @Seq outside
            // 1-15 instead of returning an empty result — surface that as a
            // 400 with a clear message, not an unhandled 500.
            return BadRequest($"Invalid health check detail request (seq={seq}): {ex.Message}");
        }
    }
}

/* ==========================================================================
   AUTHENTICATION

   Wired for cookie auth with roles, but deliberately not connected to your
   ERP user table yet: I do not have that schema. Replace the body of
   ValidateAsync in ErpUserAuthenticator when you send it. Everything else,
   including the [Authorize(Roles = ...)] filters above, already works.
========================================================================== */

public interface IUserAuthenticator
{
    Task<(bool ok, string displayName, string[] roles)> ValidateAsync(
        string username, string password, CancellationToken ct = default);
}

public sealed class ErpUserAuthenticator : IUserAuthenticator
{
    private readonly IConfiguration _config;
    public ErpUserAuthenticator(IConfiguration config) => _config = config;

    public Task<(bool ok, string displayName, string[] roles)> ValidateAsync(
        string username, string password, CancellationToken ct = default)
    {
        /* REPLACE THIS.
           Point it at your ERP user table and its existing password hashing.
           Return the department as the role: Executive, Sales, Marketing,
           Operations, Accounting, or Audit.

           Development stub follows so the app runs before that is wired.
           It is enabled only when DevAuth:Enabled is true, and Program.cs
           refuses to start with it enabled outside Development. */

        var devEnabled = _config.GetValue<bool>("DevAuth:Enabled");
        if (!devEnabled)
            return Task.FromResult((false, "", Array.Empty<string>()));

        var expected = _config["DevAuth:Password"];
        if (!string.IsNullOrEmpty(expected) && password == expected)
        {
            var role = _config[$"DevAuth:Roles:{username}"] ?? "Executive";
            return Task.FromResult((true, username, role.Split(',')));
        }

        return Task.FromResult((false, "", Array.Empty<string>()));
    }
}

[AllowAnonymous]
public sealed class AccountController : Controller
{
    private readonly IUserAuthenticator _auth;
    public AccountController(IUserAuthenticator auth) => _auth = auth;

    [HttpGet]
    public IActionResult Login(string? returnUrl = null)
    {
        ViewBag.ReturnUrl = returnUrl;
        return View();
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Login(string username, string password,
                                           string? returnUrl, CancellationToken ct)
    {
        var (ok, displayName, roles) = await _auth.ValidateAsync(username, password, ct);

        if (!ok)
        {
            // Do not reveal which half was wrong.
            ModelState.AddModelError("", "That username and password combination did not work.");
            ViewBag.ReturnUrl = returnUrl;
            return View();
        }

        var claims = new List<Claim>
        {
            new(ClaimTypes.Name, displayName),
            new(ClaimTypes.NameIdentifier, username)
        };
        claims.AddRange(roles.Select(r => new Claim(ClaimTypes.Role, r.Trim())));

        var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
        await HttpContext.SignInAsync(
            CookieAuthenticationDefaults.AuthenticationScheme,
            new ClaimsPrincipal(identity),
            new AuthenticationProperties { IsPersistent = false });

        if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
            return Redirect(returnUrl);

        return RedirectToAction(nameof(DashboardController.Executive), "Dashboard");
    }

    public async Task<IActionResult> Logout()
    {
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        return RedirectToAction(nameof(Login));
    }
}
