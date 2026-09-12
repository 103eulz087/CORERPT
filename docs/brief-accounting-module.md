# Claude Code Brief — Accounting Module

Extends the existing **CoreReporting** ASP.NET Core 8 MVC solution (the one that
already ships the Executive Overview). Reuse everything already built: the
`FilterContext` model, the `SqlReportRepository` pattern, the ClosedXML export,
the ECharts setup in `wwwroot/js`, the cold-storage CSS, and the
`@AsOfDate` / `@BranchCodes` stored-procedure parameter convention.

Two deliverables in one module: **(A)** the Finance Overview dashboard with
AR/AP aging, and **(B)** the Report Center over seven existing reporting procs.

---

## Ground rules carried from the Executive module

- Posted rows only: `TicketMaster.Status IN ('POSTED','UPDATED')` wherever the
  ledger is touched.
- `BranchCode` is **always** `varchar`. `'888'` is Head Office. Never convert
  to int, never trim into a lookup, never store the display text (`'001-DAVAO'`)
  where the code belongs.
- Account classification comes from `vw_AccountTree` and `RptMnemonicMap`, never
  from hardcoded account-code lists.
- Date ranges use `>= @From AND < DATEADD(DAY,1,@To)`, never `BETWEEN`.
- Every route in this module: `[Authorize(Roles = "Accounting,Audit,Executive")]`.

---

## PART A — Finance Overview dashboard

### A1. Two fresh aging stored procedures

Model them on the Exec procs: same parameter shape
(`@AsOfDate date`, `@BranchCodes varchar(200) = NULL` where NULL/empty = all),
same `STRING_SPLIT` branch-filter pattern, same explicit result-column CASTs so
the ADO.NET reader contract is stable.

**Confirmed facts about the source tables (from the developer):**
- AR open balance lives in `TransactionChargeSales` — columns include customer
  id, `Balance` (remaining open amount after partial payments — already net),
  and invoice.
- AP open balance lives in `APAccounts.Balance` (also remaining, not original).
- **Age from INVOICE DATE**, fixed buckets: Current / 1–30 / 31–60 / 61–90 / 90+.
- Branch comes from the **customer** table (`TransactionChargeSales` has no
  branch of its own). So AR aging must join invoice → purchaseordersummary table and filter on the
  branch code.

**First, before writing the SP bodies — read the actual tables and report back:**
1. The exact column names on `TransactionChargeSales` (invoice date column,
   customer id column, balance, invoice no) and on `APAccounts`.
2. The customer master table name and its branch-code column, and the key that
   joins `TransactionChargeSales` to it.
3. The per-customer **credit limit** and **terms** column names and their table.
4. The supplier/branch source for `APAccounts` (does `APAccounts` carry a branch
   column directly, or does branch come via a supplier join?).
5. Confirm `Balance` sign convention: open items are positive; make sure there
   are no credit balances (customer advances / supplier debit memos) that would
   net age buckets negative. If they exist, decide with the developer whether to
   exclude them or show them as a separate "unapplied credits" line.

Do NOT hardcode assumed column names. Read the schema first, fill them in, then
write the SP. If any confirmed fact above contradicts what the table actually
shows, stop and flag it rather than coding around it.

**`sp_rpt_AR_Aging`**
- Source: `TransactionChargeSales`, open items (`Balance > 0`).
- Join to customer master for branch, credit limit, terms.
- Bucket each item by `DATEDIFF(DAY, InvoiceDate, @AsOfDate)`:
  Current = 0, 1–30, 31–60, 61–90, 90+.
- Return one row per customer: customer code + name, the five bucket sums,
  total outstanding, credit limit, terms, exposure % (total / limit),
  oldest item age in days.
- Sort by total outstanding desc.
- Also return a second result set (or a rollup row) with company/branch bucket
  totals for the aging chart.

**`sp_rpt_AP_Aging`**
- Source: `APAccounts`, open items (`Balance > 0`).
- Branch per the supplier/APAccounts join found in step 4.
- Same five buckets by invoice date, grouped by supplier.
- Return per-supplier rows + bucket totals.

**A health-check addition** — extend `sp_rpt_DataHealthCheck` (or add
`sp_rpt_AR_AP_HealthCheck`) with three aging-specific checks, because these are
the ways aging silently lies:
1. Open items with a NULL or future invoice date (cannot be aged correctly).
2. Open items whose customer/supplier is missing from the master (drops out of
   every grouped total).
3. AR `Balance` total vs the GL AR-trade control account (`101030101`) balance
   as of the same date — they should tie; a gap means the subsidiary ledger and
   GL have diverged. Same for AP vs `20101/20102/20103`.

### A2. Repository + service

- Add methods to `IReportRepository` / `SqlReportRepository`: `GetArAgingAsync`,
  `GetApAgingAsync`, each taking `FilterContext`. Same `GetOrdinal`-based reader
  discipline as the Exec repo; read money as `decimal`, ints as `int`.
- New DTOs: `AgingRow` (customer/supplier, five buckets, total, limit, terms,
  exposure %, oldest age) and `AgingBucketTotals`.
- New `AccountingDashboardService` mirroring `ExecutiveDashboardService`:
  2-minute cache keyed on filter, concurrent SP calls, `forceRefresh` bypass.

### A3. Controller + view

- `AccountingController.FinanceOverview` returns the dashboard view;
  `FinanceOverviewData` returns JSON for the 5-minute poll (same pattern as
  `ExecutiveData`).
- View layout (reuse the exec view's card grid and KPI markup):
  - Row 1 — 4 KPI tiles: AR outstanding, AR past due (oxblood, with % of AR),
    DSO, AP due within 7 days.
  - Row 2 — AR aging + AP aging bucket bar charts (ECharts; Current teal →
    amber → oxblood past due).
  - Row 3 — credit-exposure table: customers sorted by exposure %, oxblood pill
    over 100%, columns limit / exposure / used % / oldest.
  - Row 4 — collections vs billings, trailing 6 months (billings from sales
    postings, collections from `OR-*` family mnemonics via `RptMnemonicMap`).
- Sidebar (Accounting role): Dashboards → Finance Overview, Health Check;
  Explore → AR Aging, AP Aging, Credit Limits; Reports → Report Center.

### A4. DSO definition — pin it down, do not guess

DSO = (AR outstanding / net credit sales over the trailing period) × days in
period. Confirm the trailing window the business wants (30/90 days) and whether
"sales" is net of VAT. Put the chosen formula in a comment in the SP so it is
auditable later.

---

## PART B — Report Center

One **config-driven report engine**, not seven hand-built pages.

### B1. Report definition config

One entry per proc: `ProcName`, `Title`, `Description`, `Category`
(sidebar group), `RenderStyle` (`Grid` | `Statement` | `PivotStatement`),
`Parameters` (subset of: `AsOfDate` | `DateRange`, `Branch`, `Account`),
`Exports` (Excel, PDF). The seven:

| Proc | Style | Params |
|------|-------|--------|
| `sp_rpt_BalanceSheetWithDate` | Statement | AsOfDate, Branch |
| `sp_rpt_TrialBalanceWithDate` | Statement | AsOfDate, Branch |
| `sp_rpt_IncomeStatementAllBranchesPivot` | PivotStatement | DateRange |
| `sp_rpt_ConsolidatedGLWithDate` | Grid | DateRange, Branch |
| `sp_rpt_GLDetailLedgerWithDate` | Grid | DateRange, Branch, Account |
| `sp_rpt_GLDetailTransactionReport` | Grid | DateRange, Branch, Account |
| `sp_rpt_BankReconciliationWithDate` | Grid | AsOfDate, Branch |

### B2. Verify each proc's "all" sentinel BEFORE wiring — critical

Every developer encodes "all branches / all accounts" differently: `NULL`,
`'ALL'`, `'888'`, `-1`, empty string. **Execute each proc, read how its
parameters actually handle the all-case, and record the real sentinel per proc
in the config.** Passing the wrong sentinel returns empty or wrong data
silently — no error to catch. This step is not optional.

While there, capture each proc's **result schema** (column names + types) so the
grid and statement renderers bind to real columns, not assumed ones.

### B3. Parameter framework

One shared Razor component that renders only the parameters a report declares.
Branch dropdown = "All" + the 13 branches (value = branch code string). Account
= "All Accounts" or a searchable specific code, shown only on the two GL-detail
reports. AsOfDate vs From/To driven by the report's `Parameters`.

### B4. Renderers

- **Grid**: sticky-header scrollable table, totals footer where the proc returns
  totals, Excel (ClosedXML) + PDF export. Reuse the Exec export code; keep
  branch/account codes as text in Excel so leading zeros survive.
- **Statement** (Balance Sheet, Trial Balance): the procs **already return a
  `type` column and an indent-`level` column** (confirmed). Map:
  - `level` → indent class (`lvl0`–`lvl3`).
  - `type` → emphasis: section header (bold uppercase, no amount), detail
    (plain), subtotal (top rule), grand total (double underline).
  - First task here: run each statement proc, read the **distinct values** in
    the type column and the level range, and build the value→class map from what
    is actually there. Report those distinct values back before finalizing.
  - Negatives in parentheses + oxblood. Confirm whether the proc returns
    negatives as signed numbers or a sign/contra flag.
  - Export preserves the hierarchy (indent as Excel indent levels).
- **PivotStatement** (Income Statement): returns **one column per branch**
  (dynamic). Read the result schema at runtime — fixed leading columns (type,
  level, account label) then treat all remaining columns as branch amount
  columns. Do NOT hardcode branch columns, so adding a branch does not break it.

### B5. Report Center landing

Card grid, one card per report: title, one-line description, the parameters it
needs, and (smaller) the proc name. Cards grouped by category. Clicking a card
opens its parameter bar → Run.

---

## Suggested build order

1. Read all source tables + all seven proc schemas/sentinels. Report findings
   back before writing anything. **(This is the step that prevents silent wrong
   numbers — do it first and fully.)**
2. `sp_rpt_AR_Aging`, `sp_rpt_AP_Aging`, aging health checks. Verify buckets
   against a hand-checked sample before wiring UI.
3. Repository + DTOs + `AccountingDashboardService`.
4. Report Center engine (config + grid renderer first — it's the simplest),
   then the statement renderer, then the pivot.
5. Finance Overview dashboard view + poll endpoint.
6. Sidebar wiring + role authorization on every route.

## What to report back to the developer (paste into chat for design review)

- The real column names found in step 1, and any confirmed-fact mismatch.
- A sample of `sp_rpt_AR_Aging` and `sp_rpt_AP_Aging` output (a few rows) so the
  buckets can be sanity-checked before the UI is trusted.
- The distinct `type` values and `level` range from the statement procs.
- Each proc's actual "all" sentinel.
- Any AR/AP-vs-GL control-account gap the health check finds.
