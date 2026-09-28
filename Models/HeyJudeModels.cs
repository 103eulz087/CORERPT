namespace CoreReporting.Models;

/// <summary>
/// "Hey Jude" — a natural-language front end over a fixed whitelist of
/// existing report intents (see HeyJudeService). The LLM only ever picks an
/// Intent + a date range + optional BranchCode/TopN/MonthsBack; it never
/// sees or writes SQL, and it never states a peso figure itself —
/// HeyJudeService renders the answer (and any chart) from the same DTOs the
/// dashboards already use, so every hard rule already baked into those
/// procs (posted-only, signed amounts, cross-branch, internal-movement
/// exclusion) carries straight through instead of being re-derived by a
/// model that can hallucinate.
/// </summary>
public enum ReportIntent
{
    Unsupported,
    SalesSummary,
    SalesTrend,
    BranchRanking,
    ArAgingSummary,
    ArTopCustomers,
    ApAgingSummary,
    ApTopSuppliers,
    DailyActivity,

    /// <summary>Sales module: sp_rpt_Agent_Scorecard, top-N agent leaderboard.</summary>
    AgentRanking,

    /// <summary>Config-driven — reads whatever exception checks currently exist
    /// in dbo.ExceptionDefinition via sp_rpt_ExceptionCenter_Summary. New
    /// checks show up here automatically with zero HeyJudeService changes,
    /// same as they do on the Exception Center page.</summary>
    ExceptionCenterSummary,

    /// <summary>Reads sp_rpt_DataHealthCheck — whichever ledger-integrity
    /// checks exist today, automatically, same "no code change needed when a
    /// check is added" property as ExceptionCenterSummary above.</summary>
    DataHealthCheck,

    /// <summary>Runs one of the Report Center's own procs generically via the
    /// same IReportRepository.RunReportAsync/ReportCatalog the Report Center
    /// page uses — full statements, ledgers and pivots. HeyJudeService never
    /// attempts to compute a total from these results (a running-balance
    /// column isn't additive across rows, a Statement's rows aren't flat) —
    /// it reports row count/scope honestly and points to the full report.</summary>
    FinancialReport,

    /// <summary>Executive dashboard: sp_rpt_Exec_InventoryByBranch, current
    /// on-hand quantity/value per branch. Always "right now" — the underlying
    /// proc has no date parameter (dbo.Inventory has no historical snapshot
    /// mechanism, see sql/24's header) — date_from/date_to are accepted (the
    /// tool schema requires them) but ignored for this intent; the answer
    /// says so rather than implying the figures are as of the requested date.</summary>
    InventoryByBranch,

    /// <summary>Executive dashboard: sp_rpt_Exec_CashPosition, point-in-time
    /// cash-on-hand + cash-in-bank balance as of date_to (same convention as
    /// ar_aging_summary/ap_aging_summary — set date_from = date_to). Two
    /// caveats every answer for this intent must carry, per CashPositionRow's
    /// doc comment: this ledger has no opening balance before 2026-07-24 (so
    /// figures are directional, not final), and every balance is Philippine
    /// pesos regardless of "USD"/"EURO" in an account's name (this ERP has no
    /// foreign-currency tracking at all).</summary>
    CashPosition,

    /// <summary>dbo.sp_rpt_ItemCostingRecon_List (ERP-owned, read-only — see
    /// docs/ItemCostingRecon_WebReporting_Handoff.md) — is stock carried at
    /// the unit cost its linked freight/handling/brokerage/duty invoices
    /// justify, for shipments (POs) ordered in a date range. Always called
    /// with @OnlyWithExpenses=1, same as the dashboard. No branch dimension
    /// (the proc returns a BranchName string, not a filterable branch code).
    /// The derived VarianceValue this reports is the money impact on the
    /// WHOLE RECEIVED BATCH, never a P&amp;L figure — every answer must carry
    /// that caveat, plus the handoff doc §9 caption that most VARIANCE
    /// shipments today are expected fallout from a pre-2026-09-24 costing
    /// bug, not new problems.</summary>
    ItemCostingRecon,

    /// <summary>dbo.sp_rpt_SupplierPriceComparison (sql/29) — landed cost per
    /// kg by PO supplier over a PO-order date range: linked ExpenseSummary
    /// invoices / received kg, weighted by kg. Ranked through the same
    /// SupplierPriceService.RollUpBySupplier the dashboard uses. Caveats every
    /// answer must carry: these are actual landed costs paid, not quotations;
    /// invoice basis (includes recoverable VAT); a mixed-product PO carries one
    /// blended ₱/kg, so a supplier-level figure is not like-for-like unless
    /// the suppliers ship the same cuts.</summary>
    SupplierPriceComparison
}

/// <summary>The LLM's tool-call arguments — its only degrees of freedom.</summary>
public sealed class RunReportArgs
{
    public ReportIntent Intent { get; set; } = ReportIntent.Unsupported;
    public DateOnly? DateFrom { get; set; }
    public DateOnly? DateTo { get; set; }

    /// <summary>Optional. Null means all branches / consolidated.</summary>
    public string? BranchCode { get; set; }

    /// <summary>For branch_ranking / ar_top_customers / ap_top_suppliers — how many rows to return.</summary>
    public int? TopN { get; set; }

    /// <summary>For sales_trend — how many months back from DateTo to chart.</summary>
    public int? MonthsBack { get; set; }

    /// <summary>For financial_report only — one of the Report Center's known
    /// slugs (see HeyJudeService.ReportSlugs). Null/unrecognized -&gt; the
    /// intent reports it doesn't know that report rather than guessing.</summary>
    public string? ReportName { get; set; }

    /// <summary>For financial_report only — free text the user said for an
    /// account (a code like "401", or a name fragment like "accounts
    /// receivable"). Resolved against the real chart of accounts in C#,
    /// never assumed correct as typed.</summary>
    public string? AccountCode { get; set; }

    /// <summary>For supplier_price_comparison only — weekly / monthly /
    /// yearly grain. Null -&gt; monthly.</summary>
    public PricePeriod? Period { get; set; }
}

public sealed class HeyJudeRequest
{
    public string Question { get; set; } = "";
}

/// <summary>A single chart-ready series. The client renders this with ECharts;
/// the server never sends pre-rendered pixels, only labeled values, so it
/// matches the app's existing dark-theme chart styling automatically.</summary>
public sealed class ChartSeries
{
    /// <summary>"bar" or "line".</summary>
    public string Type { get; set; } = "bar";
    public string Title { get; set; } = "";
    public string? ValueLabel { get; set; }
    public List<string> Labels { get; set; } = new();
    public List<decimal> Values { get; set; } = new();
}

public sealed class HeyJudeResponse
{
    public bool Ok { get; set; }
    public string Answer { get; set; } = "";
    public string? Intent { get; set; }
    public ChartSeries? Chart { get; set; }
}
