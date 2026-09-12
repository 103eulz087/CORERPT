using ClosedXML.Excel;
using CoreReporting.Data;
using CoreReporting.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CoreReporting.Controllers;

/// <summary>
/// Part B of the Accounting module: a config-driven engine over 7 existing,
/// confirmed-working sp_rpt_* procs (see Models/ReportCenterModels.cs for
/// the catalog). One controller, one generic run/export pair, rather than a
/// hand-built controller action per report.
///
/// Report Center results are on-demand/parameterized, not the 2-minute
/// dashboard cache — every run reflects exactly the parameters the user
/// picked, right now.
/// </summary>
[Authorize(Roles = "Accounting,Audit,Executive")]
public sealed class ReportCenterController : Controller
{
    private readonly IReportRepository _repo;

    public ReportCenterController(IReportRepository repo)
    {
        _repo = repo;
    }

    /// <summary>Landing page: the card grid, one card per report definition.</summary>
    [HttpGet]
    public async Task<IActionResult> ReportCenter(CancellationToken ct)
    {
        // The per-report parameter bar needs a single-select branch list
        // (each of these 7 procs takes one @BranchCode, not the Executive
        // module's CSV multi-select) — same branch source, read fresh here
        // rather than threaded through session filter state.
        ViewBag.Branches = await _repo.GetBranchesAsync(ct);

        // Same source as branches: read fresh here for the Account
        // parameter's autosuggest (GLDetailLedgerWithDate,
        // GLDetailTransactionReport, BankReconciliationWithDate).
        ViewBag.Accounts = await _repo.GetPostableAccountsAsync(ct);

        return View(ReportCatalog.All);
    }

    /// <summary>
    /// Runs one report and returns its result sets as thin JSON for the
    /// generic Grid/Statement/Pivot renderer. "All Branches"/"All Accounts"
    /// arrive as null/missing query values and are threaded through to the
    /// repository as-is; the repository is the one place that turns that
    /// into a true SQL NULL (never an empty string — see ReportRepository.
    /// BindReportParameters).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> RunReport(
        string procName,
        DateOnly? asOfDate,
        DateOnly? dateFrom,
        DateOnly? dateTo,
        string? branchCode,
        string? accountCode,
        bool includeZeroActivity = false,
        bool? includeLiveActivity = null,
        CancellationToken ct = default)
    {
        var def = ReportCatalog.Find(procName);
        if (def is null) return NotFound($"Unknown report '{procName}'.");

        try
        {
            var request = BuildRequest(def, asOfDate, dateFrom, dateTo, branchCode, accountCode, includeZeroActivity, includeLiveActivity);
            var result = await _repo.RunReportAsync(request, ct);
            return Json(ToJson(result));
        }
        catch (ArgumentException ex)
        {
            // Missing/invalid parameters (e.g. no AccountCode for a report
            // that requires one) — a 400, not a silent empty/wrong result.
            return BadRequest(ex.Message);
        }
    }

    /// <summary>
    /// Excel export for any of the 7 reports. Every result set the proc
    /// returns lands on its own worksheet, in order; text columns (codes,
    /// names) are written with the '@' format so leading zeros survive.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> Export(
        string procName,
        DateOnly? asOfDate,
        DateOnly? dateFrom,
        DateOnly? dateTo,
        string? branchCode,
        string? accountCode,
        bool includeZeroActivity = false,
        bool? includeLiveActivity = null,
        CancellationToken ct = default)
    {
        var def = ReportCatalog.Find(procName);
        if (def is null) return NotFound($"Unknown report '{procName}'.");

        ReportRunResult result;
        try
        {
            var request = BuildRequest(def, asOfDate, dateFrom, dateTo, branchCode, accountCode, includeZeroActivity, includeLiveActivity);
            result = await _repo.RunReportAsync(request, ct);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(ex.Message);
        }

        using var wb = new XLWorkbook();
        for (var s = 0; s < result.ResultSets.Count; s++)
        {
            var ws = wb.AddWorksheet($"Set {s + 1}");
            WriteResultSet(ws, result.ResultSets[s]);
        }

        using var ms = new MemoryStream();
        wb.SaveAs(ms);

        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"{def.ProcName}_{DateTime.Now:yyyyMMddHHmm}.xlsx");
    }

    /// <summary>
    /// Drill-down from a GL Detail Transaction Report row: fetches one
    /// ticket's header + full GL legs via sp_rpt_TicketDrilldown, for a
    /// modal/inline panel — not a report with its own Excel export. 400 if
    /// ticketNumber is missing; 404 (not 200 with an empty body) if the proc
    /// finds no header, i.e. the ticket does not exist or is not posted.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> TicketDrilldown(string ticketNumber, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(ticketNumber))
            return BadRequest("ticketNumber is required.");

        var result = await _repo.GetTicketDrilldownAsync(ticketNumber.Trim(), ct);
        if (result.Header is null)
            return NotFound($"Ticket '{ticketNumber}' was not found or is not posted.");

        var h = result.Header;
        return Json(new
        {
            header = new
            {
                ticketNumber = h.TicketNumber,
                ticketDate = h.TicketDate.ToString("yyyy-MM-dd"),
                supplementaryNumber = h.SupplementaryNumber,
                branchCode = h.BranchCode,
                referenceNumber = h.ReferenceNumber,
                referenceKey = h.ReferenceKey,
                origin = h.Origin,
                mnemonic = h.Mnemonic,
                remarks = h.Remarks,
                owner = h.Owner,
                enteredBy = h.EnteredBy,
                checkedBy = h.CheckedBy,
                approvedBy = h.ApprovedBy,
                status = h.Status
            },
            legs = result.Legs.Select(l => new
            {
                accountCode = l.AccountCode,
                accountTitle = l.AccountTitle,
                nature = l.Nature?.ToString(),
                debit = l.Debit,
                credit = l.Credit,
                signedAmount = l.SignedAmount,
                branchCode = l.BranchCode,
                referenceKey = l.ReferenceKey,
                referenceNumber = l.ReferenceNumber,
                costCenter = l.CostCenter,
                particulars = l.Particulars
            })
        });
    }

    /// <summary>
    /// Maps UI-facing query parameters onto a ReportRunRequest, applying
    /// only the parameters the report definition declares (e.g. a report
    /// with no Account parameter never gets an AccountCode, even if one was
    /// passed in the query string) and enforcing AccountRequired up front
    /// with a clear 400 rather than letting the repository silently run
    /// with @AccountCode = NULL against a proc with no "all accounts" mode.
    /// </summary>
    private static ReportRunRequest BuildRequest(
        ReportDefinition def,
        DateOnly? asOfDate, DateOnly? dateFrom, DateOnly? dateTo,
        string? branchCode, string? accountCode, bool includeZeroActivity,
        bool? includeLiveActivity = null)
    {
        if (def.AccountRequired && string.IsNullOrWhiteSpace(accountCode))
            throw new ArgumentException(
                $"{def.Title} requires a specific account code — it has no 'All Accounts' mode.");

        return new ReportRunRequest
        {
            ProcName = def.ProcName,
            AsOfDate = def.HasParameter(ReportParameterKind.AsOfDate) ? asOfDate : null,
            DateFrom = def.HasParameter(ReportParameterKind.DateRange) ? dateFrom : null,
            DateTo = def.HasParameter(ReportParameterKind.DateRange) ? dateTo : null,
            BranchCode = def.HasParameter(ReportParameterKind.Branch) ? branchCode : null,
            AccountCode = def.HasParameter(ReportParameterKind.Account) ? accountCode : null,
            IncludeZeroActivity = def.SupportsIncludeZeroActivity && includeZeroActivity,
            // Omitting the flag entirely still means "show live activity" —
            // Live is the whole point of choosing this report over its
            // non-Live sibling. Only an explicit false switches to the
            // tie-out/audit (posted-only) view.
            IncludeLiveActivity = !def.SupportsIncludeLiveActivity || (includeLiveActivity ?? true)
        };
    }

    private static object ToJson(ReportRunResult result) => new
    {
        procName = result.ProcName,
        renderStyle = result.RenderStyle.ToString(),
        generatedAt = result.GeneratedAt.ToString("yyyy-MM-dd HH:mm"),
        resultSets = result.ResultSets.Select(rs => new
        {
            columns = rs.Columns.Select(c => new { name = c.Name, type = c.Type.ToString() }),
            rows = rs.Rows
        })
    };

    private static void WriteResultSet(IXLWorksheet ws, ReportResultSet rs)
    {
        for (var c = 0; c < rs.Columns.Count; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = rs.Columns[c].Name;
            cell.Style.Font.Bold = true;
        }

        for (var rIdx = 0; rIdx < rs.Rows.Count; rIdx++)
        {
            var row = rs.Rows[rIdx];
            for (var c = 0; c < row.Length; c++)
                WriteCell(ws.Cell(rIdx + 2, c + 1), row[c]);
        }

        ws.SheetView.FreezeRows(1);
        ws.Columns().AdjustToContents();
    }

    /// <summary>
    /// Writes one value using its actual runtime type (not the coarse
    /// Number/Text/Date/Bool tag) so decimals get money formatting and
    /// integers do not, while every text value keeps '@' formatting so
    /// account/branch codes never lose a leading zero.
    /// </summary>
    private static void WriteCell(IXLCell cell, object? value)
    {
        switch (value)
        {
            case null:
                break;
            case string s:
                cell.SetValue(s);
                cell.Style.NumberFormat.Format = "@";
                break;
            case decimal dec:
                cell.SetValue(dec);
                cell.Style.NumberFormat.Format = "#,##0.00";
                break;
            case bool b:
                cell.SetValue(b ? "Yes" : "No");
                break;
            case DateTime dt:
                cell.SetValue(dt);
                cell.Style.NumberFormat.Format = "yyyy-mm-dd";
                break;
            case short or int or long or byte:
                cell.SetValue(Convert.ToInt64(value));
                break;
            default:
                cell.SetValue(value.ToString());
                break;
        }
    }
}
