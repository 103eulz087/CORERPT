using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using CoreReporting.Data;
using CoreReporting.Models;

namespace CoreReporting.Services;

/// <summary>
/// "Hey Jude" — one stateless question in, one plain-English answer (plus an
/// optional chart) out.
///
/// Design constraint (non-negotiable): the LLM never generates SQL and
/// never states a peso amount. It calls a single forced tool, run_report,
/// whose only fields are Intent + DateFrom/DateTo + optional
/// BranchCode/TopN/MonthsBack. This service validates those fields, runs
/// the exact same IReportRepository method the dashboards already use, and
/// renders the answer and chart itself from the resulting DTO. That is what
/// keeps every hard rule already proven in the underlying sp_rpt_* procs
/// (posted-only rows, signed amounts, cross-branch balancing, internal-
/// movement exclusion) intact — an LLM asked to "just tell me the number"
/// would eventually reproduce exactly the class of bug those procs were
/// built to avoid.
///
/// No conversation history: each question is answered independently.
/// </summary>
public sealed class HeyJudeService
{
    private readonly HttpClient _http;
    private readonly IReportRepository _repo;
    private readonly IConfiguration _config;
    private readonly ILogger<HeyJudeService> _log;

    public HeyJudeService(
        HttpClient http, IReportRepository repo, IConfiguration config, ILogger<HeyJudeService> log)
    {
        _http = http;
        _repo = repo;
        _config = config;
        _log = log;
    }

    private static readonly object RunReportTool = new
    {
        name = "run_report",
        description = "Look up one figure, ranking, or full report from CORE's reporting data: " +
                       "sales, sales trend, branch or agent ranking, AR/AP aging, top customers/" +
                       "suppliers, daily invoice activity, business-process exceptions, " +
                       "data-quality/ledger-integrity health, inventory on hand per branch, " +
                       "cash and bank position, item/landed-costing reconciliation, supplier landed " +
                       "price per kilo comparison, or a full " +
                       "financial statement/ledger/pivot from the Report Center catalog.",
        input_schema = new
        {
            type = "object",
            properties = new
            {
                intent = new
                {
                    type = "string",
                    @enum = new[]
                    {
                        "sales_summary", "sales_trend", "branch_ranking",
                        "ar_aging_summary", "ar_top_customers",
                        "ap_aging_summary", "ap_top_suppliers",
                        "daily_activity", "agent_ranking",
                        "exception_center_summary", "data_health_check",
                        "financial_report", "inventory_by_branch", "cash_position",
                        "item_costing_recon", "supplier_price_comparison", "unsupported"
                    },
                    description = "Which report answers the question."
                },
                date_from = new { type = "string", description = "YYYY-MM-DD" },
                date_to = new { type = "string", description = "YYYY-MM-DD" },
                branch_code = new
                {
                    type = "string",
                    description = "Optional branch code, e.g. '001' or '888' for Head Office. " +
                                   "Omit for consolidated/company-wide."
                },
                top_n = new
                {
                    type = "integer",
                    description = "For branch_ranking / agent_ranking / ar_top_customers / " +
                                   "ap_top_suppliers: how many rows the user wants (e.g. \"top 3\" -> 3). " +
                                   "Omit for the default."
                },
                months_back = new
                {
                    type = "integer",
                    description = "For sales_trend only: how many months back from date_to to chart " +
                                   "(e.g. \"last 6 months\" -> 6). Omit for the default."
                },
                report_name = new
                {
                    type = "string",
                    @enum = new[]
                    {
                        "balance_sheet", "balance_sheet_live", "trial_balance",
                        "income_statement_pivot", "income_statement_live",
                        "consolidated_gl", "gl_detail_ledger",
                        "gl_detail_transactions", "bank_reconciliation"
                    },
                    description = "For financial_report only — which Report Center report to run."
                },
                period = new
                {
                    type = "string",
                    @enum = new[] { "weekly", "monthly", "yearly" },
                    description = "For supplier_price_comparison only: the grain the user asked for " +
                                   "(\"weekly\", \"per month\", \"yearly\"). Omit for monthly."
                },
                account_code = new
                {
                    type = "string",
                    description = "For financial_report only, when the report needs one account " +
                                   "(gl_detail_ledger requires it; gl_detail_transactions and " +
                                   "bank_reconciliation can use one). Pass whatever the user said — " +
                                   "an exact code like \"401\" or a name like \"accounts receivable\" — " +
                                   "it is resolved against the real chart of accounts separately, " +
                                   "not by you."
                }
            },
            required = new[] { "intent", "date_from", "date_to" }
        }
    };

    /// <summary>report_name slug -&gt; the Report Center's own ProcName, the
    /// key ReportCatalog.Find (and therefore IReportRepository.RunReportAsync)
    /// actually looks up by. Kept as one small map here rather than exposing
    /// raw ProcNames to the LLM, which would be more verbose and more prone
    /// to a typo'd guess than a short, enumerated slug list.</summary>
    private static readonly IReadOnlyDictionary<string, string> ReportSlugs = new Dictionary<string, string>
    {
        ["balance_sheet"] = "sp_rpt_BalanceSheetWithDate",
        ["balance_sheet_live"] = "sp_rpt_BalanceSheetLiveWithDate",
        ["trial_balance"] = "sp_rpt_TrialBalanceWithDate",
        ["income_statement_pivot"] = "sp_rpt_IncomeStatementLiveAllBranchesPivot",
        ["income_statement_live"] = "sp_rpt_IncomeStatementLiveWithDate",
        ["consolidated_gl"] = "sp_rpt_ConsolidatedGLWithDate",
        ["gl_detail_ledger"] = "sp_rpt_GLDetailLedgerWithDate",
        ["gl_detail_transactions"] = "sp_rpt_GLDetailTransactionReport",
        ["bank_reconciliation"] = "sp_rpt_BankReconciliationWithDate"
    };

    public async Task<HeyJudeResponse> AskAsync(string? question, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(question))
        {
            return new HeyJudeResponse
            {
                Ok = false,
                Answer = "Ask me something like \"top 3 branches this month\" or " +
                         "\"what's our AR aging today?\""
            };
        }

        var apiKey = _config["Anthropic:ApiKey"];
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            return new HeyJudeResponse
            {
                Ok = false,
                Answer = "Hey Jude isn't configured yet — an administrator needs to set " +
                         "the Anthropic API key (appsettings \"Anthropic:ApiKey\", or the " +
                         "Anthropic__ApiKey environment variable on the server)."
            };
        }

        var branches = await _repo.GetBranchesAsync(ct);
        var branchList = string.Join(", ", branches.Select(b => $"{b.BranchCode}-{b.BranchName}"));
        var today = DateOnly.FromDateTime(DateTime.Today);

        var system =
            "You convert a plain-English question about this company's sales, receivables, " +
            "payables, branch performance, or daily invoice activity into exactly one call to " +
            "the run_report tool. Never answer directly in text.\n\n" +
            $"Today's date is {today:yyyy-MM-dd}. Resolve relative dates (\"today\", \"yesterday\", " +
            "\"this month\", \"last month\", \"this week\", \"last week\", \"this quarter\") against that date.\n\n" +
            $"Known branches (code-name): {branchList}. '888' is Head Office.\n\n" +
            "Intents:\n" +
            "- sales_summary: net sales / gross profit for a date range. Use this for any plain " +
            "\"sales\" or \"revenue\" question, never daily_activity.\n" +
            "- sales_trend: net sales per month for the last N months (months_back, default 6) " +
            "ending at date_to. Use for \"trend\", \"over time\", \"last few months\" questions.\n" +
            "- branch_ranking: top N branches by net sales for a date range (top_n, default 5), " +
            "or a single branch's figure if branch_code is set.\n" +
            "- ar_aging_summary / ap_aging_summary: point-in-time total outstanding + past due, " +
            "as of date_to (set date_from = date_to).\n" +
            "- ar_top_customers / ap_top_suppliers: top N (top_n, default 5) by amount outstanding, " +
            "as of date_to (set date_from = date_to).\n" +
            "- daily_activity: invoice COUNT and total amount for one specific day (date_from = " +
            "date_to). This is invoice volume, not GL-verified net sales — only use it when the " +
            "user explicitly asks about invoice counts/activity/volume, not for sales/revenue questions.\n" +
            "- agent_ranking: top N sales agents (top_n, default 5) by net sales for a date range, " +
            "including each agent's AR past-due % and DSO. Use for \"top agents\", \"who's selling " +
            "the most\", \"which agent has the most overdue AR\" questions.\n" +
            "- exception_center_summary: business-PROCESS red flags for a date range — skipped " +
            "approvals, duplicate/cancelled vouchers, credit-limit breaches, stale items, and " +
            "whatever else is currently configured in the Exception Center (this list changes over " +
            "time as new checks are added — you don't need to know their names, the tool always " +
            "returns whatever is current). Use for \"any exceptions\", \"red flags\", \"anything I " +
            "should look at\", \"audit findings\" style questions.\n" +
            "- data_health_check: ledger-INTEGRITY checks for a date range — does the math tie out " +
            "(subledger vs GL, negative balances, etc.), distinct from exception_center_summary's " +
            "process red flags. Use for \"does the ledger tie out\", \"any data quality issues\", " +
            "\"is the health check clean\" questions.\n" +
            "- financial_report: runs a full Report Center statement/ledger/pivot (report_name, " +
            "required for this intent) — balance_sheet, balance_sheet_live (includes today's " +
            "unposted activity), trial_balance, income_statement_pivot (one column per branch), " +
            "income_statement_live, consolidated_gl, gl_detail_ledger (needs account_code), " +
            "gl_detail_transactions (account_code optional), bank_reconciliation (needs " +
            "account_code — a period roll-forward for ONE bank account: opening/closing GL " +
            "balance, receipts, disbursements, and the bank-side deposits-in-transit/outstanding-" +
            "checks adjustment). Use this ONLY when the user explicitly wants the statement/ledger " +
            "itself (\"show me the balance sheet\", \"GL detail for account X\", \"trial balance as " +
            "of today\", \"reconcile the BDO account for August\") — a plain \"sales\"/\"revenue\" " +
            "question is still sales_summary, not income_statement_live. balance_sheet/" +
            "balance_sheet_live/trial_balance/consolidated_gl are as-of-date reports: set " +
            "date_from = date_to. income_statement_pivot/income_statement_live/gl_detail_ledger/" +
            "gl_detail_transactions/bank_reconciliation are date-range reports — bank_reconciliation " +
            "specifically needs a real period (e.g. a calendar month), not date_from = date_to, " +
            "since it reports a beginning-to-ending balance roll-forward over that range.\n" +
            "- inventory_by_branch: current on-hand quantity/value per branch, always \"right now\" " +
            "(this data has no historical snapshot) — set date_from = date_to regardless of what the " +
            "user asked, it's ignored either way. Use for \"which branch has the most/least stock\", " +
            "\"inventory by branch\", \"how much stock do we have\" questions.\n" +
            "- cash_position: cash-on-hand + cash-in-bank as of date_to (set date_from = date_to). " +
            "Use for \"how much cash do we have\", \"cash in bank\", \"liquid cash\", \"bank balance\" " +
            "questions. Not the same as ar_aging_summary (that's receivables, not cash).\n" +
            "- item_costing_recon: is stock carried at the unit cost its linked freight/handling/" +
            "brokerage/duty invoices justify, for shipments (POs) ORDERED in a date range (not a " +
            "point-in-time report). Use for \"landed cost\", \"item costing\", \"is our inventory " +
            "valuation right\", \"costing variance\" questions. No branch dimension — leave " +
            "branch_code unset for this intent.\n" +
            "- supplier_price_comparison: which SUPPLIER's meat cost us the least/most per kilo once " +
            "landed (supplier invoice + freight/broker/customs add-ons, divided by kilos received), " +
            "for POs ORDERED in a date range, optionally bucketed by period (weekly/monthly/yearly). " +
            "Use for \"cheapest supplier\", \"supplier price per kilo\", \"compare supplier prices\", " +
            "\"landed cost per kg by supplier\", \"are supplier prices going up\" questions. " +
            "NOT item_costing_recon (that asks whether inventory is carried at the right cost, not " +
            "which supplier is cheaper) and NOT ap_top_suppliers (that is money we still owe). " +
            "branch_code optional (receiving branch); top_n optional.\n\n" +
            "Rules:\n" +
            "- date_from and date_to are required, format YYYY-MM-DD, date_from <= date_to.\n" +
            "- branch_code is optional, one of the known codes above. Only set it when the user " +
            "names a specific branch. Omit it for company-wide / consolidated questions. It does " +
            "not apply to agent_ranking, exception_center_summary, data_health_check, or " +
            "item_costing_recon — leave it unset for those four, they have no branch dimension.\n" +
            "- ap_aging_summary and ap_top_suppliers have no branch breakdown at all (payables " +
            "aren't tracked per branch) — always leave branch_code unset for those two intents.\n" +
            "- If the question cannot be answered with one of the intents above (e.g. it wants a " +
            "narrative explanation, a prediction, or something no report in this system tracks), " +
            "set intent to \"unsupported\".\n" +
            "- You never state a peso amount yourself; you only choose the intent and parameters. " +
            "The actual figures are looked up separately and are always correct — do not second-guess them.";

        var payload = new
        {
            model = _config["Anthropic:Model"] ?? "claude-sonnet-5",
            max_tokens = 400,
            system,
            messages = new[] { new { role = "user", content = question } },
            tools = new object[] { RunReportTool },
            tool_choice = new { type = "tool", name = "run_report" }
        };

        using var req = new HttpRequestMessage(HttpMethod.Post, "v1/messages");
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", "2023-06-01");
        req.Content = JsonContent.Create(payload);

        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, ct);
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            // HttpClient.Timeout surfaces as TaskCanceledException, which IS an
            // OperationCanceledException — so the check has to be "did the
            // caller's own token fire", not "is this a cancellation exception".
            _log.LogError(ex, "Hey Jude: request to Anthropic failed");
            return new HeyJudeResponse
            {
                Ok = false,
                Answer = "I couldn't reach the AI service just now. Please try again in a moment."
            };
        }

        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            _log.LogWarning("Hey Jude: Anthropic returned {Status}: {Body}", resp.StatusCode, body);
            return new HeyJudeResponse { Ok = false, Answer = "The AI service returned an error. Please try again." };
        }

        JsonElement toolInput;
        try
        {
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStreamAsync(ct));
            var toolUse = doc.RootElement.GetProperty("content")
                .EnumerateArray()
                .FirstOrDefault(e => e.TryGetProperty("type", out var t) && t.GetString() == "tool_use");

            if (toolUse.ValueKind != JsonValueKind.Object)
            {
                return new HeyJudeResponse
                {
                    Ok = false,
                    Answer = "I didn't understand that. Try asking about sales, branch ranking, or AR/AP aging."
                };
            }

            toolInput = toolUse.GetProperty("input").Clone();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Hey Jude: could not parse Anthropic response");
            return new HeyJudeResponse { Ok = false, Answer = "The AI service returned something I couldn't read. Please try again." };
        }

        var args = ParseRunReportArgs(toolInput);
        return await RunReportAsync(args, branches, ct);
    }

    private static RunReportArgs ParseRunReportArgs(JsonElement input)
    {
        var args = new RunReportArgs();

        if (input.TryGetProperty("intent", out var intentEl) && intentEl.ValueKind == JsonValueKind.String)
        {
            args.Intent = intentEl.GetString() switch
            {
                "sales_summary" => ReportIntent.SalesSummary,
                "sales_trend" => ReportIntent.SalesTrend,
                "branch_ranking" => ReportIntent.BranchRanking,
                "ar_aging_summary" => ReportIntent.ArAgingSummary,
                "ar_top_customers" => ReportIntent.ArTopCustomers,
                "ap_aging_summary" => ReportIntent.ApAgingSummary,
                "ap_top_suppliers" => ReportIntent.ApTopSuppliers,
                "daily_activity" => ReportIntent.DailyActivity,
                "agent_ranking" => ReportIntent.AgentRanking,
                "exception_center_summary" => ReportIntent.ExceptionCenterSummary,
                "data_health_check" => ReportIntent.DataHealthCheck,
                "financial_report" => ReportIntent.FinancialReport,
                "inventory_by_branch" => ReportIntent.InventoryByBranch,
                "cash_position" => ReportIntent.CashPosition,
                "item_costing_recon" => ReportIntent.ItemCostingRecon,
                "supplier_price_comparison" => ReportIntent.SupplierPriceComparison,
                _ => ReportIntent.Unsupported
            };
        }

        if (input.TryGetProperty("date_from", out var fromEl) && fromEl.ValueKind == JsonValueKind.String &&
            DateOnly.TryParse(fromEl.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var from))
        {
            args.DateFrom = from;
        }

        if (input.TryGetProperty("date_to", out var toEl) && toEl.ValueKind == JsonValueKind.String &&
            DateOnly.TryParse(toEl.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var to))
        {
            args.DateTo = to;
        }

        if (input.TryGetProperty("branch_code", out var branchEl) && branchEl.ValueKind == JsonValueKind.String)
        {
            var code = branchEl.GetString();
            args.BranchCode = string.IsNullOrWhiteSpace(code) ? null : code!.Trim();
        }

        if (input.TryGetProperty("top_n", out var topNEl) && topNEl.ValueKind == JsonValueKind.Number &&
            topNEl.TryGetInt32(out var topN) && topN > 0)
        {
            args.TopN = topN;
        }

        if (input.TryGetProperty("months_back", out var mbEl) && mbEl.ValueKind == JsonValueKind.Number &&
            mbEl.TryGetInt32(out var mb) && mb > 0)
        {
            args.MonthsBack = mb;
        }

        if (input.TryGetProperty("report_name", out var reportEl) && reportEl.ValueKind == JsonValueKind.String)
        {
            var rn = reportEl.GetString();
            args.ReportName = string.IsNullOrWhiteSpace(rn) ? null : rn!.Trim();
        }

        if (input.TryGetProperty("period", out var periodEl) && periodEl.ValueKind == JsonValueKind.String)
        {
            var pv = periodEl.GetString();
            args.Period = string.IsNullOrWhiteSpace(pv) ? null : PricePeriodExtensions.Parse(pv);
        }

        if (input.TryGetProperty("account_code", out var acctEl) && acctEl.ValueKind == JsonValueKind.String)
        {
            var ac = acctEl.GetString();
            args.AccountCode = string.IsNullOrWhiteSpace(ac) ? null : ac!.Trim();
        }

        return args;
    }

    private async Task<HeyJudeResponse> RunReportAsync(
        RunReportArgs args, IReadOnlyList<Branch> branches, CancellationToken ct)
    {
        if (args.Intent == ReportIntent.Unsupported || args.DateFrom is null || args.DateTo is null)
        {
            return new HeyJudeResponse
            {
                Ok = false,
                Intent = args.Intent.ToString(),
                Answer = "I can currently answer questions about sales, sales trend, branch/agent " +
                         "ranking, AR/AP aging, top customers/suppliers, daily invoice activity, " +
                         "exception findings, data health, inventory on hand per branch, cash and " +
                         "bank position, item costing/landed-cost reconciliation, supplier landed " +
                         "price per kilo comparison (weekly/monthly/yearly), and I can also run " +
                         "any Report Center statement/ledger/pivot (balance sheet, trial balance, " +
                         "income statement, GL detail, bank reconciliation). Try something like " +
                         "\"top 3 branches this month\", \"cheapest supplier per kilo this year\", " +
                         "\"how much cash do we have\", or \"show me " +
                         "the balance sheet as of today\"."
            };
        }

        var from = args.DateFrom.Value;
        var to = args.DateTo.Value;
        if (from > to) (from, to) = (to, from); // defensive: never trust the model's ordering

        var filter = new FilterContext
        {
            DateFrom = from,
            DateTo = to,
            BranchCodes = string.IsNullOrWhiteSpace(args.BranchCode)
                ? new List<string>()
                : new List<string> { args.BranchCode! }
        };

        // "Past due" matches the Accounting dashboard's own definition (see
        // Views/Accounting/FinanceOverview.cshtml and accounting-dashboard.js):
        // 1-30 days is a grace period, not past due.
        static decimal PastDue(AgingBucketTotals? b) =>
            (b?.PastDue31To60 ?? 0m) + (b?.PastDue61To90 ?? 0m) + (b?.PastDue90Plus ?? 0m);

        string BranchLabel(string code) =>
            branches.FirstOrDefault(b => b.BranchCode == code)?.DisplayText ?? code;

        string answer;
        ChartSeries? chart = null;

        switch (args.Intent)
        {
            case ReportIntent.SalesSummary:
            {
                var s = await _repo.GetExecSummaryAsync(filter, ct);
                var scope = args.BranchCode is null ? "company-wide" : BranchLabel(args.BranchCode);
                answer = $"Net sales for {filter.PeriodLabel} ({scope}) were {Peso(s.NetSales)}.";
                if (s.NetSalesDeltaPct is decimal pct)
                    answer += $" That's {Math.Abs(pct):N1}% {(pct >= 0 ? "up" : "down")} from the prior period.";
                answer += $" Gross profit was {Peso(s.GrossProfit)}" +
                          (s.GrossMarginPct is decimal gm ? $" ({gm:N1}% margin)." : ".");
                break;
            }
            case ReportIntent.SalesTrend:
            {
                var monthsBack = args.MonthsBack ?? 6;
                var trend = await _repo.GetSalesTrendAsync(filter, monthsBack, ct);
                var trendScope = args.BranchCode is null ? "company-wide" : BranchLabel(args.BranchCode);
                if (trend.Count == 0)
                {
                    answer = $"No sales trend data found for the {monthsBack} months ending {to:MMM yyyy} ({trendScope}).";
                    break;
                }
                answer = $"Net sales trend for the {trend.Count} months ending {to:MMM yyyy} ({trendScope}): " +
                         string.Join(", ", trend.Select(t => $"{t.MonthLabel} {Peso(t.NetSales)}"));
                chart = new ChartSeries
                {
                    Type = "line",
                    Title = $"Net Sales Trend — {trend.Count} months ending {to:MMM yyyy} ({trendScope})",
                    ValueLabel = "Net Sales (₱)",
                    Labels = trend.Select(t => t.MonthLabel).ToList(),
                    Values = trend.Select(t => t.NetSales).ToList()
                };
                break;
            }
            case ReportIntent.BranchRanking:
            {
                var rows = await _repo.GetBranchScorecardAsync(filter, ct);

                // sp_rpt_Exec_BranchScorecard has no @BranchCodes parameter — it
                // always returns every branch. A requested branch_code MUST be
                // applied here, in C#, before picking a row: otherwise a
                // question about one branch could silently be answered with a
                // different branch's number.
                if (args.BranchCode is not null)
                {
                    var row = rows.FirstOrDefault(r => r.BranchCode == args.BranchCode);
                    answer = row is null
                        ? $"I don't have branch performance data for {BranchLabel(args.BranchCode)} in {filter.PeriodLabel}."
                        : $"For {filter.PeriodLabel}, {row.DisplayText} had {Peso(row.NetSales)} in net sales" +
                          (row.GrossMarginPct is decimal rgm ? $" ({rgm:N1}% gross margin)." : ".");
                    break;
                }

                if (rows.Count == 0)
                {
                    answer = $"No branch activity found for {filter.PeriodLabel}.";
                    break;
                }

                var topN = Math.Min(args.TopN ?? 5, rows.Count);
                var ranked = rows.OrderByDescending(r => r.NetSales).Take(topN).ToList();

                if (ranked[0].NetSales <= 0)
                {
                    answer = $"No branch had net sales above zero for {filter.PeriodLabel}.";
                    break;
                }

                answer = $"Top {ranked.Count} branch{(ranked.Count == 1 ? "" : "es")} by net sales " +
                         $"for {filter.PeriodLabel}: " +
                         string.Join(", ", ranked.Select((r, i) => $"{i + 1}) {r.DisplayText} {Peso(r.NetSales)}"));
                chart = new ChartSeries
                {
                    Type = "bar",
                    Title = $"Top {ranked.Count} Branches by Net Sales — {filter.PeriodLabel}",
                    ValueLabel = "Net Sales (₱)",
                    Labels = ranked.Select(r => r.DisplayText).ToList(),
                    Values = ranked.Select(r => r.NetSales).ToList()
                };
                break;
            }
            case ReportIntent.ArAgingSummary:
            {
                var ar = await _repo.GetArAgingAsync(filter, ct);
                var total = ar.BranchTotals.FirstOrDefault(b => b.Label == "TOTAL");
                var scope = args.BranchCode is null ? "company-wide" : BranchLabel(args.BranchCode);
                answer = $"Total AR outstanding as of {to:MMM d, yyyy} ({scope}) was {Peso(total?.TotalOutstanding ?? 0m)}, " +
                         $"of which {Peso(PastDue(total))} is past due (31+ days).";
                if (ar.Dso.Dso is decimal dso)
                    answer += $" Company DSO is {dso:N0} days.";
                break;
            }
            case ReportIntent.ArTopCustomers:
            {
                var ar = await _repo.GetArAgingAsync(filter, ct);
                var arScope = args.BranchCode is null ? "company-wide" : BranchLabel(args.BranchCode);
                if (ar.Customers.Count == 0)
                {
                    answer = $"No AR customer balances found as of {to:MMM d, yyyy} ({arScope}).";
                    break;
                }
                var topN = Math.Min(args.TopN ?? 5, ar.Customers.Count);
                var ranked = ar.Customers.OrderByDescending(c => c.TotalOutstanding).Take(topN).ToList();
                answer = $"Top {ranked.Count} customer{(ranked.Count == 1 ? "" : "s")} by AR outstanding " +
                         $"as of {to:MMM d, yyyy} ({arScope}): " +
                         string.Join(", ", ranked.Select((c, i) => $"{i + 1}) {c.CustomerName} {Peso(c.TotalOutstanding)}"));
                chart = new ChartSeries
                {
                    Type = "bar",
                    Title = $"Top {ranked.Count} Customers by AR Outstanding — as of {to:MMM d, yyyy} ({arScope})",
                    ValueLabel = "Outstanding (₱)",
                    Labels = ranked.Select(c => c.CustomerName).ToList(),
                    Values = ranked.Select(c => c.TotalOutstanding).ToList()
                };
                break;
            }
            case ReportIntent.ApAgingSummary:
            {
                var ap = await _repo.GetApAgingAsync(to, ct);
                answer = $"Total AP outstanding as of {to:MMM d, yyyy} was {Peso(ap.CompanyTotal.TotalOutstanding)}, " +
                         $"of which {Peso(PastDue(ap.CompanyTotal))} is past due (31+ days).";
                if (args.BranchCode is not null)
                    answer += " (AP aging is company-wide; it isn't tracked per branch.)";
                break;
            }
            case ReportIntent.ApTopSuppliers:
            {
                var ap = await _repo.GetApAgingAsync(to, ct);
                if (ap.Suppliers.Count == 0)
                {
                    answer = $"No AP supplier balances found as of {to:MMM d, yyyy}.";
                    break;
                }
                var topN = Math.Min(args.TopN ?? 5, ap.Suppliers.Count);
                var ranked = ap.Suppliers.OrderByDescending(s => s.TotalOutstanding).Take(topN).ToList();
                answer = $"Top {ranked.Count} supplier{(ranked.Count == 1 ? "" : "s")} by AP outstanding " +
                         $"as of {to:MMM d, yyyy}: " +
                         string.Join(", ", ranked.Select((s, i) => $"{i + 1}) {s.SupplierName} {Peso(s.TotalOutstanding)}"));
                if (args.BranchCode is not null)
                    answer += " (AP aging is company-wide; it isn't tracked per branch.)";
                chart = new ChartSeries
                {
                    Type = "bar",
                    Title = $"Top {ranked.Count} Suppliers by AP Outstanding — as of {to:MMM d, yyyy}",
                    ValueLabel = "Outstanding (₱)",
                    Labels = ranked.Select(s => s.SupplierName).ToList(),
                    Values = ranked.Select(s => s.TotalOutstanding).ToList()
                };
                break;
            }
            case ReportIntent.DailyActivity:
            {
                var day = await _repo.GetDailyBranchActivityAsync(to, ct);

                // sp_rpt_DailyBranchActivity has no branch parameter — it always
                // returns every branch with activity plus a company rollup. A
                // requested branch_code MUST be applied here, in C#, the same
                // way BranchRanking does, or a question about one branch would
                // silently be answered with the company-wide total.
                if (args.BranchCode is not null)
                {
                    var row = day.Branches.FirstOrDefault(b => b.BranchCode == args.BranchCode);
                    if (row is not null)
                    {
                        answer = $"Invoice activity for {BranchLabel(args.BranchCode)} on {to:MMM d, yyyy}: " +
                                 $"{row.InvoiceCount} invoice{(row.InvoiceCount == 1 ? "" : "s")} totaling " +
                                 $"{Peso(row.TotalAmount)}. (This counts every invoice entered for the day — " +
                                 "it is not a GL-verified net sales figure.)";
                    }
                    else if (branches.Any(b => b.BranchCode == args.BranchCode))
                    {
                        // A known branch just simply had no invoices that day —
                        // the result set only lists branches WITH activity, so
                        // absence here means zero, not an error.
                        answer = $"No invoice activity found for {BranchLabel(args.BranchCode)} on {to:MMM d, yyyy}.";
                    }
                    else
                    {
                        answer = $"I don't recognize branch code {args.BranchCode}.";
                    }
                    break;
                }

                answer = $"Invoice activity for {to:MMM d, yyyy}: {day.CompanyTotal.InvoiceCount} invoices " +
                         $"totaling {Peso(day.CompanyTotal.TotalAmount)} across all branches. " +
                         "(This counts every invoice entered for the day — it is not a GL-verified " +
                         "net sales figure; use a sales question for that.)";
                if (day.Branches.Count > 0)
                {
                    chart = new ChartSeries
                    {
                        Type = "bar",
                        Title = $"Invoice Activity by Branch — {to:MMM d, yyyy}",
                        ValueLabel = "Invoice Total (₱)",
                        Labels = day.Branches.Select(b => b.BranchName).ToList(),
                        Values = day.Branches.Select(b => b.TotalAmount).ToList()
                    };
                }
                break;
            }
            case ReportIntent.AgentRanking:
            {
                var rows = await _repo.GetAgentScorecardAsync(from, to, agentNamesCsv: null, ct);
                var agentRows = rows.Where(r => r.RowType == "AGENT").OrderByDescending(r => r.NetSales).ToList();
                if (agentRows.Count == 0)
                {
                    answer = $"No agent sales activity found for {filter.PeriodLabel}.";
                    break;
                }

                var topN = Math.Min(args.TopN ?? 5, agentRows.Count);
                var ranked = agentRows.Take(topN).ToList();

                if (ranked[0].NetSales <= 0)
                {
                    answer = $"No agent had net sales above zero for {filter.PeriodLabel}.";
                    break;
                }

                answer = $"Top {ranked.Count} agent{(ranked.Count == 1 ? "" : "s")} by net sales " +
                         $"for {filter.PeriodLabel}: " +
                         string.Join(", ", ranked.Select((r, i) =>
                             $"{i + 1}) {r.AgentLabel} {Peso(r.NetSales)}" +
                             (r.ARPastDuePct is decimal pct2 ? $" (AR past due {pct2:N1}%)" : "")));
                chart = new ChartSeries
                {
                    Type = "bar",
                    Title = $"Top {ranked.Count} Agents by Net Sales — {filter.PeriodLabel}",
                    ValueLabel = "Net Sales (₱)",
                    Labels = ranked.Select(r => r.AgentLabel).ToList(),
                    Values = ranked.Select(r => r.NetSales).ToList()
                };
                break;
            }
            case ReportIntent.ExceptionCenterSummary:
            {
                var rows = await _repo.GetExceptionCenterSummaryAsync(from, to, ct);

                // Config-driven — whatever checks exist in ExceptionDefinition
                // today, automatically, no code change needed when one is
                // added. NEVER sum ValueAtRisk across rows: sql/16's header
                // documents that several codes structurally overlap the same
                // underlying events (e.g. a cancelled check is counted once
                // as VOU-CANCELLED-CHECKS AND again as VOU-REVERSED-VOUCHERS),
                // so a naive total would double-count. List each finding's
                // own figure instead of ever presenting a grand total.
                var active = rows.Where(r => !r.IsClean)
                    .OrderByDescending(r => r.Severity == "Critical")
                    .ThenByDescending(r => r.ValueAtRisk ?? 0)
                    .ToList();

                if (active.Count == 0)
                {
                    answer = $"No exception findings for {filter.PeriodLabel} — every configured check is clean.";
                    break;
                }

                var criticals = active.Count(r => r.Severity == "Critical");
                answer = $"{active.Count} exception categor{(active.Count == 1 ? "y" : "ies")} " +
                         $"flagged for {filter.PeriodLabel}" +
                         (criticals > 0 ? $", {criticals} critical" : "") + ": " +
                         string.Join("; ", active.Take(5).Select(r =>
                             $"{r.Title} ({r.Severity}) — {r.Findings} finding{(r.Findings == 1 ? "" : "s")}" +
                             (r.ValueAtRisk is decimal var2 ? $", {Peso(var2)}" : "")));
                if (active.Count > 5)
                    answer += $"; plus {active.Count - 5} more — see the Exception Center for the full list.";
                break;
            }
            case ReportIntent.DataHealthCheck:
            {
                var rows = await _repo.GetHealthCheckAsync(from, to, ct);

                // Same no-summing discipline as ExceptionCenterSummary above —
                // these checks measure fundamentally different things (a
                // subledger-vs-GL peso gap vs. a plain finding count), so a
                // combined total would be meaningless, not just risky.
                var dirty = rows.Where(r => !r.IsClean)
                    .OrderByDescending(r => r.Severity == "CRITICAL")
                    .ThenByDescending(r => r.ValueAtRisk ?? 0)
                    .ToList();

                if (dirty.Count == 0)
                {
                    answer = $"All data health checks are clean for {filter.PeriodLabel} — the ledger ties out.";
                    break;
                }

                var hcCriticals = dirty.Count(r => r.Severity == "CRITICAL");
                answer = $"{dirty.Count} data-quality check{(dirty.Count == 1 ? "" : "s")} failing " +
                         $"for {filter.PeriodLabel}" +
                         (hcCriticals > 0 ? $", {hcCriticals} critical" : "") + ": " +
                         string.Join("; ", dirty.Take(5).Select(r =>
                             $"{r.CheckName} — {r.Findings} finding{(r.Findings == 1 ? "" : "s")}" +
                             (r.ValueAtRisk is decimal var3 ? $", {Peso(var3)}" : "")));
                if (dirty.Count > 5)
                    answer += $"; plus {dirty.Count - 5} more — see Health Check for the full list.";
                break;
            }
            case ReportIntent.InventoryByBranch:
            {
                // No @AsOfDate parameter on this proc at all — always "right
                // now" (see sql/24's header). date_from/date_to were required
                // by the tool schema and are simply unused here.
                var rows = await _repo.GetInventoryByBranchAsync(ct);

                if (args.BranchCode is not null)
                {
                    var row = rows.FirstOrDefault(r => r.BranchCode == args.BranchCode);
                    answer = row is null
                        ? $"I don't have inventory data for {BranchLabel(args.BranchCode)}."
                        : $"{row.DisplayText} currently has {row.OnHandQuantity:N0} units on hand, " +
                          $"worth {Peso(row.OnHandValue)}" +
                          (row.ZeroCostQuantityPct is decimal zc && zc > 1
                              ? $" ({zc:N1}% of that quantity has no recorded cost, so this value is understated)."
                              : ".");
                    break;
                }

                if (rows.Count == 0)
                {
                    answer = "No inventory data is available right now.";
                    break;
                }

                var ranked = rows.OrderByDescending(r => r.OnHandValue).ToList();
                var highest = ranked[0];
                var lowest = ranked[^1];
                var topN = Math.Min(args.TopN ?? 5, ranked.Count);
                var top = ranked.Take(topN).ToList();

                answer = "Inventory by branch, right now (this is always current, not tied to a " +
                         $"date range): highest is {highest.DisplayText} at {Peso(highest.OnHandValue)}, " +
                         $"lowest is {lowest.DisplayText} at {Peso(lowest.OnHandValue)}. Top {top.Count}: " +
                         string.Join(", ", top.Select((r, i) => $"{i + 1}) {r.DisplayText} {Peso(r.OnHandValue)}"));
                chart = new ChartSeries
                {
                    Type = "bar",
                    Title = $"Top {top.Count} Branches by On-Hand Inventory Value",
                    ValueLabel = "On-Hand Value (₱)",
                    Labels = top.Select(r => r.DisplayText).ToList(),
                    Values = top.Select(r => r.OnHandValue).ToList()
                };
                break;
            }
            case ReportIntent.CashPosition:
            {
                var rows = await _repo.GetCashPositionAsync(filter, ct);

                if (rows.Count == 0)
                {
                    answer = $"No posted cash/bank activity found as of {to:MMM d, yyyy}" +
                             (args.BranchCode is null ? "." : $" for {BranchLabel(args.BranchCode)}.");
                    break;
                }

                // Aggregate by account (summed across branches) — same as the
                // Executive dashboard's own cash card. The per-branch split
                // this proc returns is remittance-attribution detail (see
                // CashPositionRow's doc comment), not "which branch owns this
                // account", so it isn't the right unit for a ranked answer.
                var byAccount = rows
                    .GroupBy(r => new { r.AccountCode, r.AccountName })
                    .Select(g => new { g.Key.AccountName, Balance = g.Sum(r => r.Balance) })
                    .OrderByDescending(x => x.Balance)
                    .ToList();

                var total = rows.Sum(r => r.Balance);
                var inBank = rows.Where(r => r.Classification == "Cash in Bank").Sum(r => r.Balance);
                var onHand = rows.Where(r => r.Classification == "Cash on Hand").Sum(r => r.Balance);
                var cashScope = args.BranchCode is null ? "company-wide" : BranchLabel(args.BranchCode);

                // Same two disclosures the dashboard card carries, kept short
                // but never dropped — see CashPositionRow's doc comment for why.
                answer = $"As of {to:MMM d, yyyy} ({cashScope}), total cash & bank is {Peso(total)} " +
                         $"({Peso(inBank)} in bank, {Peso(onHand)} on hand). This excludes any opening " +
                         "balance from before this ledger's earliest posted transaction, and every " +
                         "figure is Philippine pesos regardless of \"USD\"/\"EURO\" in an account's " +
                         "name — this ERP doesn't track foreign currency separately, so treat " +
                         "individual account figures as directional until confirmed against actual " +
                         "bank statements.";

                if (args.TopN is int cashTopN && cashTopN > 0 && byAccount.Count > 1)
                {
                    var top = byAccount.Take(Math.Min(cashTopN, byAccount.Count)).ToList();
                    answer += " Top accounts: " +
                              string.Join(", ", top.Select((a, i) => $"{i + 1}) {a.AccountName} {Peso(a.Balance)}"));
                    chart = new ChartSeries
                    {
                        Type = "bar",
                        Title = $"Top {top.Count} Cash/Bank Accounts — as of {to:MMM d, yyyy} ({cashScope})",
                        ValueLabel = "Balance (₱)",
                        Labels = top.Select(a => a.AccountName).ToList(),
                        Values = top.Select(a => a.Balance).ToList()
                    };
                }
                break;
            }
            case ReportIntent.ItemCostingRecon:
            {
                // Always @OnlyWithExpenses=1, same as the dashboard — NO
                // EXPENSES rows would add meaningless "variance" (the full
                // live unit cost with nothing to reconcile against). Date
                // range here is PO ORDER date, not a point-in-time report.
                var (shipments, _) = await _repo.GetItemCostingReconAsync(
                    from, to, shipmentNo: null, onlyWithExpenses: true, ct);

                if (shipments.Count == 0)
                {
                    answer = $"No shipments with linked expenses to reconcile for {filter.PeriodLabel}.";
                    break;
                }

                // By ReconStatus label, NOT the IsMatched flag — the two can
                // disagree (a NO INVENTORY/LOTS DIVERGE row can algebraically
                // satisfy the tolerance test while being classified
                // differently). See ItemCostingReconService.BuildAsync's
                // MatchRatePct comment for the full reasoning.
                var matched = shipments.Count(s => s.ReconStatus == "MATCHED");
                var needingAttention = shipments.Count(s =>
                    s.ReconStatus is "VARIANCE" or "LOTS DIVERGE" or "NO INVENTORY");
                var varianceRows = shipments.Where(s => s.ReconStatus == "VARIANCE").ToList();
                var netVariance = varianceRows.Sum(s => s.VarianceValue);
                var grossVariance = varianceRows.Sum(s => Math.Abs(s.VarianceValue));
                var matchRatePct = matched * 100m / shipments.Count;

                answer = $"For {filter.PeriodLabel} (by PO order date), {shipments.Count} shipment" +
                         $"{(shipments.Count == 1 ? "" : "s")} had linked expenses to reconcile: " +
                         $"{matched} matched ({matchRatePct:N1}%), {needingAttention} needing attention " +
                         "(variance, lots-diverge, or no-inventory). Net variance value is " +
                         $"{Peso(netVariance)}, gross variance exposure {Peso(grossVariance)} — these " +
                         "are the valuation gap on the RECEIVED BATCH, not a P&L figure, and some of " +
                         "that stock may already be sold. Most VARIANCE shipments today trace back to " +
                         "a pre-2026-09-24 whole-invoice costing bug that was fixed going forward but " +
                         "not retroactively corrected — a high count isn't necessarily new problems. " +
                         "See the Item Costing Recon dashboard for the shipment-by-shipment detail.";

                if (varianceRows.Count > 0)
                {
                    var topN = Math.Min(args.TopN ?? 5, varianceRows.Count);
                    var top = varianceRows.OrderByDescending(s => Math.Abs(s.VarianceValue)).Take(topN).ToList();
                    chart = new ChartSeries
                    {
                        Type = "bar",
                        Title = $"Top {top.Count} Shipments by |Variance Value| — {filter.PeriodLabel}",
                        ValueLabel = "Variance Value (₱)",
                        Labels = top.Select(s => $"{s.ShipmentNo} - {s.SupplierName}").ToList(),
                        Values = top.Select(s => s.VarianceValue).ToList()
                    };
                }
                break;
            }
            case ReportIntent.SupplierPriceComparison:
            {
                // Same proc + same whole-range rollup as the Supplier Price
                // Comparison page, so the ranking here can't drift from it.
                var grain = args.Period ?? PricePeriod.Monthly;
                var data = await _repo.GetSupplierPriceComparisonAsync(
                    from, to, grain, branchCodesCsv: filter.BranchCsv, ct: ct);

                var ranked = SupplierPriceService.RollUpBySupplier(data.Shipments);
                var notReceived = data.Shipments.Count(s => s.PriceStatus == "NOT RECEIVED");
                var incomplete = data.Shipments.Count(s => s.PriceStatus == "INCOMPLETE");
                var unposted = data.Shipments.Where(s => s.PriceStatus == "PRICED").Sum(s => s.UnpostedExpenseCount);
                var branchLabel = filter.BranchCodes.Count > 0 ? $" (branch {string.Join(", ", filter.BranchCodes)})" : "";
                if (ranked.Count == 0)
                {
                    answer = $"No POs ordered {filter.PeriodLabel} have both linked invoices and received kilos, " +
                             "so there's no landed cost per kilo to compare yet" +
                             (notReceived + incomplete > 0
                                 ? $" ({notReceived} have invoices but nothing received, {incomplete} have kilos but no invoice from the PO supplier yet)."
                                 : ".");
                    break;
                }

                var totalKg = ranked.Sum(r => r.ReceivedKg);
                var totalLanded = ranked.Sum(r => r.TotalLandedAmount);
                var mixed = ranked.Sum(r => r.MixedShipments);
                var shipments = ranked.Sum(r => r.Shipments);
                var cheapest = ranked[0];
                var dearest = ranked[^1];

                var topN = Math.Min(args.TopN ?? 5, ranked.Count);
                var shown = ranked.Take(topN).ToList();
                var list = string.Join("; ", shown.Select((r, i) =>
                    $"{i + 1}. {r.SupplierName} {PerKg(r.LandedCostPerKg)} ({r.ReceivedKg:N0} kg)"));

                answer = $"Landed cost per kilo by supplier for POs ordered {filter.PeriodLabel}" +
                         branchLabel +
                         $": {ranked.Count} supplier{(ranked.Count == 1 ? "" : "s")}, {shipments} priced " +
                         $"shipment{(shipments == 1 ? "" : "s")}, {totalKg:N0} kg, weighted average " +
                         $"{PerKg(totalKg == 0 ? 0 : totalLanded / totalKg)}. Cheapest first — {list}." +
                         (ranked.Count > 1
                             ? $" Spread cheapest-to-dearest: {PerKg(dearest.LandedCostPerKg - cheapest.LandedCostPerKg)}."
                             : "") +
                         " These are actual landed costs paid (supplier invoice plus freight/broker/customs " +
                         "add-ons, divided by kilos received), not quotations, and on the invoice basis, so " +
                         "they include any recoverable VAT. This ranking compares whatever each supplier " +
                         "shipped, so a beef supplier is ranked against a pork supplier; use the By product " +
                         "table on the page for a like-for-like comparison. The latest period may still be " +
                         "missing freight or customs invoices." +
                         (mixed > 0
                             ? $" {mixed} of those shipments mixed several products into one blended ₱/kg, so " +
                               "compare suppliers like-for-like in the By product table before drawing conclusions."
                             : "") +
                         (notReceived > 0 ? $" {notReceived} shipment{(notReceived == 1 ? " has" : "s have")} invoices but nothing received yet, left out." : "") +
                         (incomplete > 0 ? $" {incomplete} shipment{(incomplete == 1 ? " has" : "s have")} kilos but no invoice from the PO supplier yet, left out so they don't look artificially cheap." : "") +
                         (unposted > 0 ? $" {unposted} of the invoices counted aren't posted to the GL yet." : "") +
                         PeriodMovement(data.SupplierPeriods, grain) +
                         $" The {grain.Label().ToLowerInvariant()} breakdown by supplier is on the Supplier Price Comparison page.";

                chart = new ChartSeries
                {
                    Type = "bar",
                    Title = $"Landed ₱/kg by supplier, cheapest first — {filter.PeriodLabel}{branchLabel}",
                    ValueLabel = "₱ per kg",
                    Labels = shown.Select(r => r.SupplierName).ToList(),
                    Values = shown.Select(r => Math.Round(r.LandedCostPerKg, 2)).ToList()
                };
                break;
            }
            case ReportIntent.FinancialReport:
            {
                if (string.IsNullOrWhiteSpace(args.ReportName) ||
                    !ReportSlugs.TryGetValue(args.ReportName, out var procName))
                {
                    answer = "I can run: Balance Sheet, Balance Sheet (Live), Trial Balance, " +
                             "Income Statement (pivot or live), Consolidated GL, GL Detail Ledger, " +
                             "GL Detail Transaction Report, or Bank Reconciliation. Which one?";
                    break;
                }

                var def = ReportCatalog.Find(procName);
                if (def is null)
                {
                    answer = $"\"{args.ReportName}\" isn't wired up correctly — this shouldn't happen; please report it.";
                    break;
                }

                // Account resolution: the LLM never guesses a code — it passes
                // through whatever free text the user said, and this is
                // resolved here against the REAL chart of accounts, the same
                // source of truth the Report Center's own parameter bar uses.
                string? resolvedAccountCode = null;
                if (def.HasParameter(ReportParameterKind.Account))
                {
                    if (string.IsNullOrWhiteSpace(args.AccountCode))
                    {
                        if (def.AccountRequired)
                        {
                            answer = $"{def.Title} needs a specific account — which one (code or name)?";
                            break;
                        }
                    }
                    else
                    {
                        var accounts = await _repo.GetPostableAccountsAsync(ct);
                        var exact = accounts.FirstOrDefault(a =>
                            string.Equals(a.AccountCode, args.AccountCode, StringComparison.OrdinalIgnoreCase));
                        if (exact is not null)
                        {
                            resolvedAccountCode = exact.AccountCode;
                        }
                        else
                        {
                            var byName = accounts.Where(a =>
                                a.Description.Contains(args.AccountCode, StringComparison.OrdinalIgnoreCase)).ToList();
                            if (byName.Count == 1)
                            {
                                resolvedAccountCode = byName[0].AccountCode;
                            }
                            else if (byName.Count > 1)
                            {
                                answer = $"\"{args.AccountCode}\" matches {byName.Count} accounts: " +
                                         string.Join(", ", byName.Take(8).Select(a => $"{a.AccountCode}-{a.Description}")) +
                                         ". Ask again with the exact code.";
                                break;
                            }
                            else
                            {
                                answer = $"I couldn't find an account matching \"{args.AccountCode}\". " +
                                         "Check the exact code or name in Report Center.";
                                break;
                            }
                        }
                    }
                }

                var request = new ReportRunRequest
                {
                    ProcName = procName,
                    AsOfDate = def.HasParameter(ReportParameterKind.AsOfDate) ? to : null,
                    DateFrom = def.HasParameter(ReportParameterKind.DateRange) ? from : null,
                    DateTo = def.HasParameter(ReportParameterKind.DateRange) ? to : null,
                    BranchCode = string.IsNullOrWhiteSpace(args.BranchCode) ? null : args.BranchCode,
                    AccountCode = resolvedAccountCode,
                    IncludeLiveActivity = true
                };

                ReportRunResult result;
                try
                {
                    result = await _repo.RunReportAsync(request, ct);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _log.LogWarning(ex, "Hey Jude: financial_report run failed for {Proc}", procName);
                    answer = $"I couldn't run {def.Title} with those parameters — try adjusting the date range, branch, or account.";
                    break;
                }

                var reportScope = args.BranchCode is null ? "company-wide" : BranchLabel(args.BranchCode);
                var whenLabel = def.HasParameter(ReportParameterKind.AsOfDate) ? $"as of {to:MMM d, yyyy}" : filter.PeriodLabel;
                var rs = result.ResultSets.FirstOrDefault();
                var rowCount = rs?.Rows.Count ?? 0;

                // Deliberately NO computed total here. This proc's rows can be
                // a flat grid (safe-looking, but e.g. a running-balance column
                // is not additive across rows) or a Statement/PivotStatement
                // hierarchy (a naive sum would double-count subtotal rows
                // against their own detail rows) — the row count is the one
                // thing that's always honest to report without knowing each
                // report's specific column semantics. See ReportIntent.
                // FinancialReport's XML doc for the full reasoning.
                answer = $"{def.Title} {whenLabel} ({reportScope}" +
                          (resolvedAccountCode is not null ? $", account {resolvedAccountCode}" : "") +
                          $") — {rowCount} line{(rowCount == 1 ? "" : "s")}" +
                          (rowCount > 0 ? "." : ", nothing matched those parameters.") +
                          $" Open {def.Title} in Report Center for the full breakdown.";
                break;
            }
            default:
                answer = "I can currently answer questions about sales, branch/agent ranking, " +
                         "AR/AP aging, exceptions, data health, and Report Center statements/ledgers.";
                break;
        }

        return new HeyJudeResponse { Ok = true, Intent = args.Intent.ToString(), Answer = answer, Chart = chart };
    }

    private static string Peso(decimal v) => "₱" + v.ToString("N2", CultureInfo.InvariantCulture);

    /// <summary>All-supplier weighted ₱/kg in the first vs the last period
    /// of the range, from result set 2's own sums (never an average of
    /// per-supplier rates). Empty when fewer than two periods have data.</summary>
    private static string PeriodMovement(IReadOnlyList<SupplierPeriodRow> rows, PricePeriod grain)
    {
        var byPeriod = rows
            .GroupBy(r => r.PeriodStart)
            .OrderBy(g => g.Key)
            .Select(g => new
            {
                Label = g.First().PeriodLabel,
                Kg = g.Sum(r => r.ReceivedKg),
                Amt = g.Sum(r => r.TotalLandedAmount)
            })
            .Where(p => p.Kg > 0)
            .ToList();
        if (byPeriod.Count < 2)
            return "";

        var first = byPeriod[0];
        var last = byPeriod[^1];
        var a = first.Amt / first.Kg;
        var b = last.Amt / last.Kg;
        var pct = a == 0 ? 0 : (b - a) * 100m / a;
        return $" {grain.Label()} view: the all-supplier weighted landed cost went from {PerKg(a)} in " +
               $"{first.Label} to {PerKg(b)} in {last.Label} ({(pct >= 0 ? "+" : "")}{pct:N1}%). That " +
               "movement mixes product mix, freight and the peso rate, not just supplier pricing.";
    }

    private static string PerKg(decimal v) => "₱" + v.ToString("N2", CultureInfo.InvariantCulture) + "/kg";
}
