using System.Data;
using CoreReporting.Models;
using Microsoft.Data.SqlClient;

namespace CoreReporting.Data;

public interface IReportRepository
{
    Task<IReadOnlyList<Branch>> GetBranchesAsync(CancellationToken ct = default);

    /// <summary>Postable (AccountType = 'D') accounts from dbo.ChartOfAccounts,
    /// for the Report Center's Account parameter autosuggest.</summary>
    Task<IReadOnlyList<AccountOption>> GetPostableAccountsAsync(CancellationToken ct = default);
    Task<ExecSummary> GetExecSummaryAsync(FilterContext f, CancellationToken ct = default);
    Task<IReadOnlyList<SalesTrendPoint>> GetSalesTrendAsync(FilterContext f, int monthsBack, CancellationToken ct = default);
    Task<IReadOnlyList<BranchScorecardRow>> GetBranchScorecardAsync(FilterContext f, CancellationToken ct = default);
    Task<IReadOnlyList<FlowStage>> GetFlowBarAsync(FilterContext f, CancellationToken ct = default);
    Task<IReadOnlyList<HealthCheckItem>> GetHealthCheckAsync(DateOnly from, DateOnly to, CancellationToken ct = default);

    /// <summary>
    /// Drill-down behind one row of sp_rpt_DataHealthCheck (Seq 1-15), via
    /// dbo.sp_rpt_DataHealthCheckDetail. Read generically exactly the way
    /// RunReportAsync reads the Report Center's 7 procs (GetName/GetFieldType/
    /// GetValue, one ReportResultSet per result set) rather than a typed DTO
    /// per check — columns vary per Seq, and Seq 12/13 (AR/AP subledger-vs-GL
    /// tie-out) return three result sets instead of one. An out-of-range Seq
    /// makes the proc itself raise a SQL error (RAISERROR/THROW) rather than
    /// return an empty result; that surfaces here as a thrown SqlException —
    /// callers must not swallow it, so the controller can turn it into a 400.
    /// </summary>
    Task<ReportRunResult> GetHealthCheckDetailAsync(
        int seq, DateOnly dateFrom, DateOnly dateTo, DateOnly? asOfDate, CancellationToken ct = default);

    /* ---- Accounting module: Part A (AR/AP aging) ------------------------ */
    Task<ArAgingResult> GetArAgingAsync(FilterContext f, CancellationToken ct = default);
    Task<ApAgingResult> GetApAgingAsync(DateOnly asOfDate, CancellationToken ct = default);

    /// <summary>sp_rpt_APEXP_Aging — non-trade AP (ExpenseSummary), company-
    /// wide like sp_rpt_AP_Aging. See sql/09-apexp-aging.sql.</summary>
    Task<ApExpAgingResult> GetApExpAgingAsync(DateOnly asOfDate, CancellationToken ct = default);

    /// <summary>sp_rpt_DailyBranchActivity — today's per-branch invoice count
    /// and peso total, plus a company-wide rollup. Pass null to let the proc
    /// default @ForDate to today (do not compute "today" in C# and pass it
    /// explicitly — the SQL default owns that).</summary>
    Task<DailyBranchActivityResult> GetDailyBranchActivityAsync(DateOnly? forDate, CancellationToken ct = default);

    /* ---- Accounting module: Part B (Report Center engine) --------------- */
    Task<ReportRunResult> RunReportAsync(ReportRunRequest request, CancellationToken ct = default);

    /// <summary>Reads dbo.vw_rpt_AccountBSClassification into a lookup keyed by
    /// AccountCode. Used to enrich sp_rpt_BalanceSheetWithDate's result set 1
    /// only — see RunReportAsync.</summary>
    Task<IReadOnlyDictionary<string, AccountBsClassification>> GetAccountBsClassificationAsync(CancellationToken ct = default);

    /// <summary>
    /// Drill-down from a GL Detail Transaction Report row: full header + GL
    /// legs for one ticket, via dbo.sp_rpt_TicketDrilldown. Header is null
    /// when the ticket does not exist or is not posted (0 rows in result
    /// set 1) — callers must check this before trusting Legs.
    /// </summary>
    Task<TicketDrilldownResult> GetTicketDrilldownAsync(string ticketNumber, CancellationToken ct = default);
}

public sealed class SqlReportRepository : IReportRepository
{
    private readonly string _connectionString;
    private readonly ILogger<SqlReportRepository> _log;

    public SqlReportRepository(IConfiguration config, ILogger<SqlReportRepository> log)
    {
        _connectionString = config.GetConnectionString("Erp")
            ?? throw new InvalidOperationException(
                "Connection string 'Erp' is not configured. Set ConnectionStrings__Erp " +
                "as an environment variable on the server.");
        _log = log;
    }

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        return conn;
    }

    private static SqlCommand Proc(SqlConnection conn, string name) =>
        new(name, conn)
        {
            CommandType = CommandType.StoredProcedure,
            // Reporting scans can be slow on first run before the plan caches.
            CommandTimeout = 120
        };

    /* ---------- readers -------------------------------------------------
       GetOrdinal + IsDBNull rather than indexer-by-name on every access:
       it is both faster and it fails loudly if a column is renamed in the
       procedure, instead of silently returning a default.
    --------------------------------------------------------------------- */

    private static decimal Dec(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        return r.IsDBNull(i) ? 0m : r.GetDecimal(i);
    }

    private static decimal? DecN(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        return r.IsDBNull(i) ? null : r.GetDecimal(i);
    }

    private static string Str(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        return r.IsDBNull(i) ? "" : r.GetString(i);
    }

    private static string? StrN(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        return r.IsDBNull(i) ? null : r.GetString(i);
    }

    /// <summary>Reads a nullable char(1) column (e.g. Nature). SqlClient
    /// surfaces SQL char/varchar as string, never as System.Char, so this
    /// reads via GetString and takes the first character rather than
    /// GetChar/GetFieldValue&lt;char&gt;, which throw InvalidCastException here.</summary>
    private static char? CharN(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        if (r.IsDBNull(i)) return null;
        var s = r.GetString(i);
        return s.Length > 0 ? s[0] : null;
    }

    private static int Int(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        // Convert.ToInt32(GetValue), not GetInt32/GetFieldValue<int>: several
        // source columns (e.g. ChartOfAccounts.LevelNumber) are smallint, and
        // Microsoft.Data.SqlClient throws InvalidCastException from either of
        // those on anything narrower than int rather than widening it.
        // Convert.ToInt32 widens smallint/byte -> int correctly while still
        // failing loudly (throws) on a genuinely non-numeric column.
        return r.IsDBNull(i) ? 0 : Convert.ToInt32(r.GetValue(i));
    }

    private static int? IntN(SqlDataReader r, string col)
    {
        var i = r.GetOrdinal(col);
        return r.IsDBNull(i) ? null : Convert.ToInt32(r.GetValue(i));
    }

    public async Task<IReadOnlyList<Branch>> GetBranchesAsync(CancellationToken ct = default)
    {
        var list = new List<Branch>();
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(
            "SELECT BranchCode, BranchName FROM dbo.Branches ORDER BY BranchCode", conn);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new Branch
            {
                // BranchCode stays a string. Never Convert.ToInt32 here.
                BranchCode = Str(r, "BranchCode"),
                BranchName = Str(r, "BranchName")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<AccountOption>> GetPostableAccountsAsync(CancellationToken ct = default)
    {
        var list = new List<AccountOption>();
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(
            "SELECT AccountCode, Description FROM dbo.ChartOfAccounts " +
            "WHERE AccountType = 'D' ORDER BY AccountCode", conn);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new AccountOption
            {
                // AccountCode stays a string — never Convert.ToInt32.
                AccountCode = Str(r, "AccountCode"),
                Description = Str(r, "Description")
            });
        }
        return list;
    }

    public async Task<ExecSummary> GetExecSummaryAsync(FilterContext f, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_Exec_Summary");
        cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = f.DateFrom.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = f.DateTo.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@BranchCodes", SqlDbType.VarChar, 200).Value =
            (object?)f.BranchCsv ?? DBNull.Value;

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return new ExecSummary();

        return new ExecSummary
        {
            AsOf = r.GetDateTime(r.GetOrdinal("AsOf")),
            NetSales = Dec(r, "NetSales"),
            NetSalesPrior = Dec(r, "NetSalesPrior"),
            OtherIncome = Dec(r, "OtherIncome"),
            Cogs = Dec(r, "COGS"),
            CogsPrior = Dec(r, "COGSPrior"),
            GrossProfit = Dec(r, "GrossProfit"),
            GrossMarginPct = DecN(r, "GrossMarginPct"),
            GrossMarginPctPrior = DecN(r, "GrossMarginPctPrior"),
            OperatingExpense = Dec(r, "OperatingExpense"),
            OperatingExpensePrior = Dec(r, "OperatingExpensePrior"),
            NetIncome = Dec(r, "NetIncome"),
            CashPosition = Dec(r, "CashPosition"),
            ReceivablesTrade = Dec(r, "ReceivablesTrade"),
            PayablesTrade = Dec(r, "PayablesTrade"),
            InventoryOnHand = Dec(r, "InventoryOnHand"),
            InventoryInTransit = Dec(r, "InventoryInTransit")
        };
    }

    public async Task<IReadOnlyList<SalesTrendPoint>> GetSalesTrendAsync(
        FilterContext f, int monthsBack, CancellationToken ct = default)
    {
        var list = new List<SalesTrendPoint>();
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_Exec_SalesTrend");
        cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = f.DateTo.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@MonthsBack", SqlDbType.Int).Value = monthsBack;
        cmd.Parameters.Add("@BranchCodes", SqlDbType.VarChar, 200).Value =
            (object?)f.BranchCsv ?? DBNull.Value;

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new SalesTrendPoint
            {
                MonthStart = r.GetDateTime(r.GetOrdinal("MonthStart")),
                MonthLabel = Str(r, "MonthLabel"),
                NetSales = Dec(r, "NetSales"),
                Cogs = Dec(r, "COGS"),
                GrossProfit = Dec(r, "GrossProfit"),
                GrossMarginPct = DecN(r, "GrossMarginPct")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<BranchScorecardRow>> GetBranchScorecardAsync(
        FilterContext f, CancellationToken ct = default)
    {
        var list = new List<BranchScorecardRow>();
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_Exec_BranchScorecard");
        cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = f.DateFrom.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = f.DateTo.ToDateTime(TimeOnly.MinValue);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new BranchScorecardRow
            {
                BranchCode = Str(r, "BranchCode"),
                BranchName = Str(r, "BranchName"),
                DisplayText = Str(r, "DisplayText"),
                NetSales = Dec(r, "NetSales"),
                Cogs = Dec(r, "COGS"),
                OperatingExpense = Dec(r, "OperatingExpense"),
                GrossProfit = Dec(r, "GrossProfit"),
                GrossMarginPct = DecN(r, "GrossMarginPct"),
                Receivables = Dec(r, "Receivables"),
                Inventory = Dec(r, "Inventory"),
                Payables = Dec(r, "Payables")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<FlowStage>> GetFlowBarAsync(
        FilterContext f, CancellationToken ct = default)
    {
        var list = new List<FlowStage>();
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_Exec_FlowBar");
        cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = f.DateTo.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@BranchCodes", SqlDbType.VarChar, 200).Value =
            (object?)f.BranchCsv ?? DBNull.Value;

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new FlowStage
            {
                StageOrder = r.GetInt32(r.GetOrdinal("StageOrder")),
                StageKey = Str(r, "StageKey"),
                StageLabel = Str(r, "StageLabel"),
                Amount = DecN(r, "Amount"),
                IsAvailable = r.GetInt32(r.GetOrdinal("IsAvailable")) == 1
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<HealthCheckItem>> GetHealthCheckAsync(
        DateOnly from, DateOnly to, CancellationToken ct = default)
    {
        var list = new List<HealthCheckItem>();
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_DataHealthCheck");
        cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = from.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = to.ToDateTime(TimeOnly.MinValue);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new HealthCheckItem
            {
                Seq = Int(r, "Seq"),
                CheckName = Str(r, "CheckName"),
                Severity = Str(r, "Severity"),
                Findings = r.GetInt32(r.GetOrdinal("Findings")),
                ValueAtRisk = DecN(r, "ValueAtRisk")
            });
        }
        return list;
    }

    /// <summary>
    /// dbo.sp_rpt_DataHealthCheckDetail — the drill-down behind one Health
    /// Check row. Same generic multi-result-set read as RunReportAsync
    /// below: columns are not known in advance (they vary per Seq, and Seq
    /// 12/13 return three result sets), so this reads them positionally via
    /// GetName/GetFieldType/GetValue rather than a per-check typed DTO.
    /// @AsOfDate binds DBNull.Value when null — the proc itself defaults it
    /// to @DateTo. An invalid @Seq (not 1-15) makes the proc RAISERROR/THROW,
    /// which ExecuteReaderAsync surfaces as a SqlException; this method does
    /// not catch it, so it propagates to the controller.
    /// </summary>
    public async Task<ReportRunResult> GetHealthCheckDetailAsync(
        int seq, DateOnly dateFrom, DateOnly dateTo, DateOnly? asOfDate, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_DataHealthCheckDetail");
        cmd.Parameters.Add("@Seq", SqlDbType.Int).Value = seq;
        cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = dateFrom.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = dateTo.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value =
            asOfDate.HasValue ? asOfDate.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value;

        var resultSets = new List<ReportResultSet>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        do
        {
            var columns = new ReportColumn[r.FieldCount];
            for (var i = 0; i < r.FieldCount; i++)
                columns[i] = new ReportColumn { Name = r.GetName(i), Type = MapColumnType(r.GetFieldType(i)) };

            var rows = new List<object?[]>();
            while (await r.ReadAsync(ct))
            {
                var values = new object?[r.FieldCount];
                for (var i = 0; i < r.FieldCount; i++)
                    values[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                rows.Add(values);
            }

            resultSets.Add(new ReportResultSet { Columns = columns, Rows = rows });
        } while (await r.NextResultAsync(ct));

        return new ReportRunResult
        {
            ProcName = "sp_rpt_DataHealthCheckDetail",
            RenderStyle = ReportRenderStyle.Grid,
            ResultSets = resultSets
        };
    }

    /* ======================================================================
       PART A — AR / AP AGING
       Column names below are the exact result-set columns from
       sql/05-accounting-aging.sql — read live, not guessed.
    ====================================================================== */

    public async Task<ArAgingResult> GetArAgingAsync(FilterContext f, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_AR_Aging");
        cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = f.DateTo.ToDateTime(TimeOnly.MinValue);
        cmd.Parameters.Add("@BranchCodes", SqlDbType.VarChar, 200).Value =
            (object?)f.BranchCsv ?? DBNull.Value;

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: one row per customer.
        var customers = new List<ArAgingRow>();
        while (await r.ReadAsync(ct))
        {
            customers.Add(new ArAgingRow
            {
                CustomerKey = Str(r, "CustomerKey"),
                CustomerName = Str(r, "CustomerName"),
                BranchCode = Str(r, "BranchCode"),
                CurrentAmount = Dec(r, "CurrentAmount"),
                PastDue1To30 = Dec(r, "PastDue1_30"),
                PastDue31To60 = Dec(r, "PastDue31_60"),
                PastDue61To90 = Dec(r, "PastDue61_90"),
                PastDue90Plus = Dec(r, "PastDue90Plus"),
                TotalOutstanding = Dec(r, "TotalOutstanding"),
                CreditLimit = DecN(r, "CreditLimit"),
                Term = IntN(r, "Term"),
                ExposurePct = DecN(r, "ExposurePct"),
                OldestAgeDays = Int(r, "OldestAgeDays")
            });
        }

        // Result set 2: branch rollup + a 'TOTAL' row.
        var branchTotals = new List<AgingBucketTotals>();
        if (await r.NextResultAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                branchTotals.Add(new AgingBucketTotals
                {
                    Label = Str(r, "BranchCode"),
                    CurrentAmount = Dec(r, "CurrentAmount"),
                    PastDue1To30 = Dec(r, "PastDue1_30"),
                    PastDue31To60 = Dec(r, "PastDue31_60"),
                    PastDue61To90 = Dec(r, "PastDue61_90"),
                    PastDue90Plus = Dec(r, "PastDue90Plus"),
                    TotalOutstanding = Dec(r, "TotalOutstanding")
                });
            }
        }

        // Result set 3: single company-wide DSO row.
        var dso = new DsoInfo();
        if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
        {
            dso = new DsoInfo
            {
                AsOfDate = DateOnly.FromDateTime(r.GetDateTime(r.GetOrdinal("AsOfDate"))),
                AROutstanding = Dec(r, "AROutstanding"),
                NetSales90Day = Dec(r, "NetSales90Day"),
                TrailingDays = Int(r, "TrailingDays"),
                Dso = DecN(r, "DSO")
            };
        }

        return new ArAgingResult
        {
            Customers = customers,
            BranchTotals = branchTotals,
            Dso = dso
        };
    }

    public async Task<ApAgingResult> GetApAgingAsync(DateOnly asOfDate, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_AP_Aging");
        cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = asOfDate.ToDateTime(TimeOnly.MinValue);

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: one row per supplier (including UNKNOWN SUPPLIER rows).
        var suppliers = new List<ApAgingRow>();
        while (await r.ReadAsync(ct))
        {
            suppliers.Add(new ApAgingRow
            {
                SupplierId = Str(r, "SupplierID"),
                SupplierName = Str(r, "SupplierName"),
                CurrentAmount = Dec(r, "CurrentAmount"),
                PastDue1To30 = Dec(r, "PastDue1_30"),
                PastDue31To60 = Dec(r, "PastDue31_60"),
                PastDue61To90 = Dec(r, "PastDue61_90"),
                PastDue90Plus = Dec(r, "PastDue90Plus"),
                TotalOutstanding = Dec(r, "TotalOutstanding"),
                OldestAgeDays = Int(r, "OldestAgeDays")
            });
        }

        // Result set 2: single company-wide rollup row (no label column of its own).
        var companyTotal = new AgingBucketTotals { Label = "TOTAL" };
        if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
        {
            companyTotal = new AgingBucketTotals
            {
                Label = "TOTAL",
                CurrentAmount = Dec(r, "CurrentAmount"),
                PastDue1To30 = Dec(r, "PastDue1_30"),
                PastDue31To60 = Dec(r, "PastDue31_60"),
                PastDue61To90 = Dec(r, "PastDue61_90"),
                PastDue90Plus = Dec(r, "PastDue90Plus"),
                TotalOutstanding = Dec(r, "TotalOutstanding")
            };
        }

        return new ApAgingResult
        {
            Suppliers = suppliers,
            CompanyTotal = companyTotal
        };
    }

    /// <summary>
    /// sp_rpt_APEXP_Aging — non-trade AP aging (dbo.ExpenseSummary), company-
    /// wide (no branch parameter, matching sp_rpt_AP_Aging's signature).
    /// Column names are the exact result-set columns from
    /// sql/09-apexp-aging.sql — read live, not guessed.
    /// </summary>
    public async Task<ApExpAgingResult> GetApExpAgingAsync(DateOnly asOfDate, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_APEXP_Aging");
        cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = asOfDate.ToDateTime(TimeOnly.MinValue);

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: one row per supplier (including UNKNOWN SUPPLIER rows).
        var suppliers = new List<ApExpAgingRow>();
        while (await r.ReadAsync(ct))
        {
            suppliers.Add(new ApExpAgingRow
            {
                SupplierId = Str(r, "SupplierID"),
                SupplierName = Str(r, "SupplierName"),
                CurrentAmount = Dec(r, "CurrentAmount"),
                PastDue1To30 = Dec(r, "PastDue1_30"),
                PastDue31To60 = Dec(r, "PastDue31_60"),
                PastDue61To90 = Dec(r, "PastDue61_90"),
                PastDue90Plus = Dec(r, "PastDue90Plus"),
                TotalOutstanding = Dec(r, "TotalOutstanding"),
                OldestAgeDays = Int(r, "OldestAgeDays")
            });
        }

        // Result set 2: single company-wide rollup row (no label column of its own).
        var companyTotal = new AgingBucketTotals { Label = "TOTAL" };
        if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
        {
            companyTotal = new AgingBucketTotals
            {
                Label = "TOTAL",
                CurrentAmount = Dec(r, "CurrentAmount"),
                PastDue1To30 = Dec(r, "PastDue1_30"),
                PastDue31To60 = Dec(r, "PastDue31_60"),
                PastDue61To90 = Dec(r, "PastDue61_90"),
                PastDue90Plus = Dec(r, "PastDue90Plus"),
                TotalOutstanding = Dec(r, "TotalOutstanding")
            };
        }

        return new ApExpAgingResult
        {
            Suppliers = suppliers,
            CompanyTotal = companyTotal
        };
    }

    /// <summary>
    /// sp_rpt_DailyBranchActivity — today's per-branch invoice activity. When
    /// forDate is null, @ForDate binds DBNull.Value so the proc's own default
    /// (today) applies; we never compute "today" here and pass it explicitly.
    /// Result set 2 (company rollup) is documented as always present and
    /// zero-safe, but this still guards with NextResultAsync/ReadAsync rather
    /// than assuming a row, matching the defensive pattern used elsewhere in
    /// this class.
    /// </summary>
    public async Task<DailyBranchActivityResult> GetDailyBranchActivityAsync(
        DateOnly? forDate, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_DailyBranchActivity");
        cmd.Parameters.Add("@ForDate", SqlDbType.Date).Value =
            forDate.HasValue ? forDate.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value;

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: one row per branch with activity, TotalAmount DESC.
        var branches = new List<DailyBranchActivityRow>();
        while (await r.ReadAsync(ct))
        {
            branches.Add(new DailyBranchActivityRow
            {
                BranchCode = Str(r, "BranchCode"),
                BranchName = Str(r, "BranchName"),
                InvoiceCount = Int(r, "InvoiceCount"),
                TotalAmount = Dec(r, "TotalAmount")
            });
        }

        // Result set 2: single company-wide rollup row.
        var companyTotal = new DailyActivityTotal();
        if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
        {
            companyTotal = new DailyActivityTotal
            {
                InvoiceCount = Int(r, "InvoiceCount"),
                TotalAmount = Dec(r, "TotalAmount")
            };
        }

        return new DailyBranchActivityResult
        {
            Branches = branches,
            CompanyTotal = companyTotal
        };
    }

    /* ======================================================================
       PART B — REPORT CENTER ENGINE

       One generic runner for all 7 procs. Column names are read at runtime
       (GetName/GetFieldType/GetValue) rather than hardcoded per report,
       because the whole point of the Report Center is a config-driven
       renderer, not seven hand-built pages. Parameter binding IS
       proc-specific (each proc's signature differs) and lives in
       BindReportParameters below — this is also where the "All branches /
       All accounts must be a true SQL NULL, never an empty string" rule is
       enforced in one place.
    ====================================================================== */

    public async Task<ReportRunResult> RunReportAsync(ReportRunRequest request, CancellationToken ct = default)
    {
        var def = ReportCatalog.Find(request.ProcName)
            ?? throw new ArgumentException($"Unknown Report Center proc '{request.ProcName}'.", nameof(request));

        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo." + def.ProcName);
        BindReportParameters(cmd, def, request);

        var resultSets = new List<ReportResultSet>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        do
        {
            var columns = new ReportColumn[r.FieldCount];
            for (var i = 0; i < r.FieldCount; i++)
                columns[i] = new ReportColumn { Name = r.GetName(i), Type = MapColumnType(r.GetFieldType(i)) };

            var rows = new List<object?[]>();
            while (await r.ReadAsync(ct))
            {
                var values = new object?[r.FieldCount];
                for (var i = 0; i < r.FieldCount; i++)
                    values[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                rows.Add(values);
            }

            resultSets.Add(new ReportResultSet { Columns = columns, Rows = rows });
        } while (await r.NextResultAsync(ct));

        // Narrow, explicit special case — do NOT generalize this to "try to
        // enrich every report". Only the Balance Sheet's flat result set 1
        // (AccountCode/AccountDescription/Amount/RawEndingBalance) is missing
        // the section/hierarchy info the Statement renderer needs; the other
        // procs are untouched. sp_rpt_BalanceSheetLiveWithDate returns the
        // exact same result-set-1 shape (same synthetic CURRENT_EARNINGS row
        // too) so it reuses this enrichment as-is.
        if ((string.Equals(def.ProcName, "sp_rpt_BalanceSheetWithDate", StringComparison.OrdinalIgnoreCase)
             || string.Equals(def.ProcName, "sp_rpt_BalanceSheetLiveWithDate", StringComparison.OrdinalIgnoreCase))
            && resultSets.Count > 0)
        {
            await EnrichBalanceSheetResultSet(resultSets[0], ct);
        }

        return new ReportRunResult
        {
            ProcName = def.ProcName,
            RenderStyle = def.RenderStyle,
            ResultSets = resultSets
        };
    }

    /// <summary>
    /// Adds BSSection/IndentLevel columns to sp_rpt_BalanceSheetWithDate's (and
    /// sp_rpt_BalanceSheetLiveWithDate's, identical result-set-1 shape) result
    /// set 1, joined in C# by AccountCode against
    /// dbo.vw_rpt_AccountBSClassification (the proc itself is developer-owned
    /// and not to be touched — see sql/06-account-bs-classification.sql).
    /// The synthetic 'CURRENT_EARNINGS' row the proc emits has no
    /// ChartOfAccounts match, so it can never appear in that view; it is
    /// force-classified as '5-Equity' here to match the proc's own Set 2
    /// SectionTotal, per that script's documented special case.
    /// </summary>
    private async Task EnrichBalanceSheetResultSet(ReportResultSet resultSet, CancellationToken ct)
    {
        var accountCodeIndex = -1;
        for (var i = 0; i < resultSet.Columns.Count; i++)
        {
            if (string.Equals(resultSet.Columns[i].Name, "AccountCode", StringComparison.OrdinalIgnoreCase))
            {
                accountCodeIndex = i;
                break;
            }
        }
        if (accountCodeIndex < 0)
        {
            // Proc shape changed underneath us — fail loudly rather than
            // silently shipping a Balance Sheet with no section grouping.
            _log.LogWarning(
                "sp_rpt_BalanceSheetWithDate result set 1 has no AccountCode column; " +
                "skipping BS section enrichment.");
            return;
        }

        var classification = await GetAccountBsClassificationAsync(ct);

        var newColumns = new List<ReportColumn>(resultSet.Columns)
        {
            new() { Name = "BSSection", Type = ReportColumnType.Text },
            new() { Name = "IndentLevel", Type = ReportColumnType.Number }
        };

        var newRows = new List<object?[]>(resultSet.Rows.Count);
        foreach (var row in resultSet.Rows)
        {
            var accountCode = row[accountCodeIndex] as string ?? "";

            string? bsSection;
            int? indentLevel;

            if (string.Equals(accountCode, "CURRENT_EARNINGS", StringComparison.OrdinalIgnoreCase))
            {
                bsSection = "5-Equity";
                indentLevel = 1; // peer of the other Equity detail lines
            }
            else if (classification.TryGetValue(accountCode, out var c))
            {
                bsSection = c.BSSection;
                indentLevel = c.IndentLevel;
            }
            else
            {
                bsSection = null;
                indentLevel = null;
            }

            var newRow = new object?[row.Length + 2];
            Array.Copy(row, newRow, row.Length);
            newRow[row.Length] = bsSection;
            newRow[row.Length + 1] = indentLevel;
            newRows.Add(newRow);
        }

        resultSet.Columns = newColumns;
        resultSet.Rows = newRows;
    }

    /// <summary>
    /// Reads dbo.vw_rpt_AccountBSClassification (see sql/06-account-bs-
    /// classification.sql) into a lookup keyed by AccountCode. Used only to
    /// enrich sp_rpt_BalanceSheetWithDate's result set 1 — see
    /// EnrichBalanceSheetResultSet.
    /// </summary>
    public async Task<IReadOnlyDictionary<string, AccountBsClassification>> GetAccountBsClassificationAsync(
        CancellationToken ct = default)
    {
        var map = new Dictionary<string, AccountBsClassification>(StringComparer.OrdinalIgnoreCase);
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(
            "SELECT AccountCode, BSSection, IndentLevel, ParentAccountCode " +
            "FROM dbo.vw_rpt_AccountBSClassification", conn);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var accountCode = Str(r, "AccountCode");
            map[accountCode] = new AccountBsClassification
            {
                BSSection = StrN(r, "BSSection"),
                IndentLevel = IntN(r, "IndentLevel"),
                ParentAccountCode = StrN(r, "ParentAccountCode")
            };
        }
        return map;
    }

    /* ======================================================================
       TICKET DRILLDOWN — see Models/ReportCenterModels.cs for DTOs.
    ====================================================================== */

    public async Task<TicketDrilldownResult> GetTicketDrilldownAsync(
        string ticketNumber, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "dbo.sp_rpt_TicketDrilldown");
        cmd.Parameters.Add("@TicketNumber", SqlDbType.VarChar, 50).Value = ticketNumber;

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: header, 0 or 1 row. No row -> ticket not found / not
        // posted -> Header stays null, which the controller turns into 404.
        TicketHeader? header = null;
        if (await r.ReadAsync(ct))
        {
            header = new TicketHeader
            {
                TicketNumber = Str(r, "TicketNumber"),
                TicketDate = r.GetDateTime(r.GetOrdinal("TicketDate")),
                SupplementaryNumber = Int(r, "SupplementaryNumber"),
                BranchCode = Str(r, "BranchCode"),
                ReferenceNumber = Str(r, "ReferenceNumber"),
                ReferenceKey = Str(r, "ReferenceKey"),
                Origin = Str(r, "Origin"),
                Mnemonic = Str(r, "Mnemonic"),
                Remarks = Str(r, "Remarks"),
                Owner = Str(r, "Owner"),
                EnteredBy = Str(r, "EnteredBy"),
                CheckedBy = Str(r, "CheckedBy"),
                ApprovedBy = Str(r, "ApprovedBy"),
                Status = Str(r, "Status")
            };
        }

        // Result set 2: GL legs, 0..N rows, already ordered by the proc.
        var legs = new List<TicketLeg>();
        if (await r.NextResultAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                legs.Add(new TicketLeg
                {
                    AccountCode = Str(r, "AccountCode"),
                    AccountTitle = StrN(r, "AccountTitle"),
                    Nature = CharN(r, "Nature"),
                    Debit = Dec(r, "Debit"),
                    Credit = Dec(r, "Credit"),
                    SignedAmount = Dec(r, "SignedAmount"),
                    BranchCode = Str(r, "BranchCode"),
                    ReferenceKey = Str(r, "ReferenceKey"),
                    ReferenceNumber = Str(r, "ReferenceNumber"),
                    CostCenter = Str(r, "CostCenter"),
                    Particulars = Str(r, "Particulars")
                });
            }
        }

        return new TicketDrilldownResult { Header = header, Legs = legs };
    }

    /// <summary>
    /// CRITICAL: "All Branches" / "All Accounts" bind as DBNull.Value, never
    /// an empty string. Passing '' silently returns an all-zero result on
    /// every one of these procs (confirmed live); passing '888' or 'ALL'
    /// silently returns Head-Office-only or wrong data. No exceptions.
    /// </summary>
    private static void BindReportParameters(SqlCommand cmd, ReportDefinition def, ReportRunRequest req)
    {
        void AddBranch()
        {
            var p = cmd.Parameters.Add("@BranchCode", SqlDbType.VarChar, 5);
            p.Value = string.IsNullOrWhiteSpace(req.BranchCode) ? DBNull.Value : req.BranchCode.Trim();
        }

        void AddAccount(bool required)
        {
            if (required && string.IsNullOrWhiteSpace(req.AccountCode))
                throw new ArgumentException(
                    $"AccountCode is required for {def.ProcName} — it has no 'all accounts' mode.");
            var p = cmd.Parameters.Add("@AccountCode", SqlDbType.VarChar, 20);
            p.Value = string.IsNullOrWhiteSpace(req.AccountCode) ? DBNull.Value : req.AccountCode.Trim();
        }

        DateTime AsOfOrThrow() => (req.AsOfDate ?? throw new ArgumentException(
            $"AsOfDate is required for {def.ProcName}.")).ToDateTime(TimeOnly.MinValue);

        (DateTime from, DateTime to) RangeOrThrow()
        {
            if (req.DateFrom is null || req.DateTo is null)
                throw new ArgumentException($"DateFrom and DateTo are required for {def.ProcName}.");
            return (req.DateFrom.Value.ToDateTime(TimeOnly.MinValue), req.DateTo.Value.ToDateTime(TimeOnly.MinValue));
        }

        switch (def.ProcName)
        {
            case "sp_rpt_BalanceSheetWithDate":
            case "sp_rpt_TrialBalanceWithDate":
                AddBranch();
                cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = AsOfOrThrow();
                break;

            case "sp_rpt_BalanceSheetLiveWithDate":
                // Unlike sp_rpt_BalanceSheetWithDate, neither bit parameter
                // has a SQL-side default — both must always be supplied.
                AddBranch();
                cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = AsOfOrThrow();
                cmd.Parameters.Add("@IncludeLiveActivity", SqlDbType.Bit).Value = req.IncludeLiveActivity;
                cmd.Parameters.Add("@IncludeZeroActivity", SqlDbType.Bit).Value = req.IncludeZeroActivity;
                break;

            case "sp_rpt_IncomeStatementLiveWithDate":
            {
                // Single-branch or consolidated (unlike the AllBranchesPivot
                // sibling) — @BranchCode follows the same NULL-for-"all
                // branches" discipline as every other proc here. Neither bit
                // parameter has a SQL-side default.
                AddBranch();
                var (from, to) = RangeOrThrow();
                cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = from;
                cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = to;
                cmd.Parameters.Add("@IncludeLiveActivity", SqlDbType.Bit).Value = req.IncludeLiveActivity;
                cmd.Parameters.Add("@IncludeZeroActivity", SqlDbType.Bit).Value = req.IncludeZeroActivity;
                break;
            }

            case "sp_rpt_IncomeStatementLiveAllBranchesPivot":
            {
                var (from, to) = RangeOrThrow();
                cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = from;
                cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = to;
                cmd.Parameters.Add("@IncludeLiveActivity", SqlDbType.Bit).Value = req.IncludeLiveActivity;
                break;
            }

            case "sp_rpt_ConsolidatedGLWithDate":
                // No @BranchCode on this proc — consolidated by design.
                // Mode is driven by which date input the user picked:
                // an as-of date -> 'TB' (point-in-time balances);
                // a date range  -> 'IS' (period activity).
                if (req.AsOfDate is not null)
                {
                    cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = req.AsOfDate.Value.ToDateTime(TimeOnly.MinValue);
                    cmd.Parameters.Add("@PeriodFrom", SqlDbType.Date).Value = DBNull.Value;
                    cmd.Parameters.Add("@PeriodTo", SqlDbType.Date).Value = DBNull.Value;
                    cmd.Parameters.Add("@ReportType", SqlDbType.VarChar, 5).Value = "TB";
                }
                else if (req.DateFrom is not null && req.DateTo is not null)
                {
                    cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = DBNull.Value;
                    cmd.Parameters.Add("@PeriodFrom", SqlDbType.Date).Value = req.DateFrom.Value.ToDateTime(TimeOnly.MinValue);
                    cmd.Parameters.Add("@PeriodTo", SqlDbType.Date).Value = req.DateTo.Value.ToDateTime(TimeOnly.MinValue);
                    cmd.Parameters.Add("@ReportType", SqlDbType.VarChar, 5).Value = "IS";
                }
                else
                {
                    throw new ArgumentException(
                        "sp_rpt_ConsolidatedGLWithDate needs either AsOfDate (balances) or DateFrom/DateTo (activity).");
                }
                break;

            case "sp_rpt_GLDetailLedgerWithDate":
            {
                AddBranch();
                AddAccount(required: true);
                var (from, to) = RangeOrThrow();
                cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = from;
                cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = to;
                break;
            }

            case "sp_rpt_GLDetailTransactionReport":
            {
                AddBranch();
                AddAccount(required: false);
                var (from, to) = RangeOrThrow();
                cmd.Parameters.Add("@DateFrom", SqlDbType.Date).Value = from;
                cmd.Parameters.Add("@DateTo", SqlDbType.Date).Value = to;
                cmd.Parameters.Add("@IncludeZeroActivity", SqlDbType.Bit).Value = req.IncludeZeroActivity;
                break;
            }

            case "sp_rpt_BankReconciliationWithDate":
                AddBranch();
                AddAccount(required: true);
                cmd.Parameters.Add("@AsOfDate", SqlDbType.Date).Value = AsOfOrThrow();
                break;

            default:
                throw new ArgumentException($"Unknown Report Center proc '{def.ProcName}'.");
        }
    }

    private static ReportColumnType MapColumnType(Type t)
    {
        if (t == typeof(decimal) || t == typeof(int) || t == typeof(short) ||
            t == typeof(long) || t == typeof(double) || t == typeof(float) || t == typeof(byte))
            return ReportColumnType.Number;
        if (t == typeof(DateTime) || t == typeof(DateOnly))
            return ReportColumnType.Date;
        if (t == typeof(bool))
            return ReportColumnType.Bool;
        return ReportColumnType.Text;
    }
}
