# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# CORE Reporting Portal

Project memory for Claude Code. Read this first, every session.

---

## What this is

A **read-only reporting & analytics portal** layered on top of an existing
C# WinForms + DevExpress meat-trading ERP (project CORECSJFC2026). The portal
does not write to the ERP. It reads the ledger and subsidiary tables through
`sp_rpt_*` stored procedures and renders dashboards + a Report Center for six
departments: Executive, Sales, Marketing, Operations, Accounting, Audit.

**Business:** B2B importer/wholesaler of frozen meat selling to hotels and
restaurants. End-to-end ERP: purchasing → stock transfers (HO↔branch,
branch↔branch) → sales → accounting.

**Stack:** ASP.NET Core 8 MVC + Razor (server-rendered), Microsoft.Data.SqlClient
(ADO.NET, no EF), ClosedXML for Excel, QuestPDF planned for PDF, ECharts 5.5 via
CDN, cookie auth with department roles. Deployed to IIS on Windows Server.

**No WebSockets.** Refresh is manual + 5-minute polling of thin JSON endpoints.

---

## Build status

- **Executive Overview** — BUILT. `sp_rpt_Exec_*` procs (summary, trend,
  branch scorecard, flow bar, inventory-by-branch, cash position) + Health
  Check + full MVC module.
- **Accounting (Finance Overview)** — BUILT. AR/AP aging dashboard + Report
  Center over the `ReportCatalog` procs (9 as of 2026-09-28). See `docs/brief-accounting-module.md`.
- **Sales (Agent Scorecard)** — BUILT.
- **Exception Center** — BUILT. Config-driven categories (SoD, Vouchering,
  Post Expense, AR, Sales, Purchasing, Inventory).
- **Hey Jude** — BUILT. Natural-language Q&A over the intents above, voice
  input/output. See "Hey Jude must stay current" below — every new report
  ships with a matching intent in the same pass.
- **Item Costing Reconciliation** — BUILT (2026-09-28). Landed-cost vs.
  carried-unit-cost variance per shipment, over two ERP-owned read-only procs
  (`sp_rpt_ItemCostingRecon_List`/`_ExpenseTickets` — do not alter, see
  `docs/ItemCostingRecon_WebReporting_Handoff.md`). Open questions from that
  handoff's §10 (production DB choice, per-user branch filtering, received-
  qty vs. on-hand variance, whether to wait on the historical cost
  correction) are still with the developer, unresolved.
- **Supplier Price Comparison** — BUILT, NOT YET APPLIED TO THE DB (2026-09-29).
  Landed ₱/kg by PO supplier, weekly/monthly/yearly, over
  `sp_rpt_SupplierPriceComparison` (`sql/29`): linked `ExpenseSummary`
  invoices ÷ `PODETAILS.ActualQuantity`, weighted by kg, cross-checked per
  shipment against `sp_rpt_ItemCostingRecon_List`. Written while the DB was
  unreachable — apply to COREX001 and run `sql/29`'s smoke tests + "VERIFY
  LIVE" list before trusting it. Caveats and open questions:
  `docs/brief-supplier-price-comparison.md`.
- Marketing, Operations, Audit — designed (see `docs/`), not built.

---

## Commands

```
dotnet build
dotnet run                    # loads appsettings.Development.json -> DEV db, DevAuth stub login
dotnet publish -c Release -r win-x64 --self-contained false -o ./publish
```

No test project exists yet. If `dotnet` is missing in a cloud container, `apt-get update && apt-get install -y dotnet-sdk-8.0` works (Microsoft's own download host may be blocked by the network policy). `dotnet run` uses the `DevAuth` stub in
`appsettings.Development.json` (`Controllers/DashboardController.cs`,
`ErpUserAuthenticator`) — log in with one of the configured passwords
(`exec`/`acct`/`audit`/`admin`) mapped to department roles. `Program.cs`
refuses to start if `DevAuth:Enabled` is true outside Development, or if the
`Erp` connection string is missing — both are fail-fast startup guards, not
bugs to work around. Hey Jude calls the Anthropic API via a typed
`HttpClient` registered in `Program.cs`; with no `Anthropic:ApiKey`
configured it degrades to a friendly message instead of failing startup.

---

## Database connections

Credentials are NOT in this file. They live in `.claude/db.local.md`, which is
gitignored (as of 2026-09-26 that file is missing from this checkout — restore
it; until then the same values are readable from `appsettings.Development.json`,
which is tracked in git and should NOT be where secrets live long-term).

Two tiers, same SQL Server (`corex.itcoreapps.com`):

- **Development DB (default): `COREX001`**. As of 2026-09-27 this is the sole
  default dev tier — apply new/altered tables, stored procedures, functions
  and views here FIRST, by default, without asking, same free-DDL treatment
  the old default (`CORECSERP_002_DEV`, now retired — see below) used to get.
  This is what the local app points at (`appsettings.Development.json`).
  **Important nuance kept from its prior "production-value preview" role:**
  this database was seeded by copying production-value data from the old
  `CORECSERP_002_DEV`, so unlike a typical throwaway dev sandbox it can hold
  real-looking figures — write DDL freely, but don't assume the data itself is
  disposable test fixtures the way a from-scratch dev DB's would be. Two
  historical incidents on this DB, kept for context: (1) it was created at SQL
  Server's default compatibility level 120, which doesn't support
  `STRING_SPLIT` (used by nearly every `sp_rpt_*` proc's CSV filter params) —
  raised to 160 on 2026-09-26 (`CORECSERP_002_DEV` had the same fix applied
  earlier via `sql/04-dev-compat-level-160.sql`, 2026-09-11); (2) when it was
  a manually-refreshed mirror of `CORECSERP_002_DEV`, three shared procs were
  found to have silently drifted stale for several days before a routine
  verification caught it; (3) `ExceptionDefinition.IsActive` has no `DEFAULT`
  constraint on COREX001, unlike its apparent DEV-side default — an
  `INSERT`/`MERGE` that omits `IsActive` from its column list (a shorthand
  that works fine against DEV) throws "Cannot insert the value NULL into
  column 'IsActive'" here (found 2026-09-28, see `sql/26`). This is a genuine
  **structural** schema difference, not just a data-snapshot one — always
  include `IsActive` explicitly in any `ExceptionDefinition` write, and don't
  assume every other DEV-side shorthand still holds without checking. Neither
  drift nor compat-level should recur now that this is the single default
  tier (no more copy-and-fall-behind), but if another mirror/preview database
  is ever introduced, check its compat level, proc currency, and column
  defaults before pointing the app at it.
- **Staging DB: `CORECSJFC2026_STAGING`**.
  NEVER apply schema changes (tables, SPs, functions, views) to staging without
  explicitly asking the developer first and getting a yes. Reads are fine;
  writes/DDL require confirmation every time.

**Retired 2026-09-27: `CORECSERP_002_DEV`.** Was the original default dev
tier; superseded by `COREX001` per the developer's explicit instruction.
**This file wins over stale copies:** as of 2026-09-28 `README.md`,
`.claude/agents/db-report-engineer.md`, and the `db-change-protocol`,
`new-report-module` and `aging-sp-pattern` skills still name
`CORECSERP_002_DEV` as the default target — read those as `COREX001`. Do
not create new objects there going forward — if you find yourself about to,
that's a sign of working from a stale assumption; check with the developer.

### DB change protocol (non-negotiable)
1. New or altered DDL → `COREX001` by default, no confirmation needed.
2. Before touching `CORECSJFC2026_STAGING` with any DDL, STOP and ask — every
   time, not just the first time.
3. Every reporting object is `sp_rpt_*`. It only reads. If a proc would INSERT/
   UPDATE/DELETE base tables, that is a bug — stop and flag it.
4. Save every DDL script to `/sql/` in the repo so changes are reviewable and
   replayable. Never apply a change that exists only as an ad-hoc query.
5. **Shared, monolithic procs** (e.g. `sp_rpt_ExceptionCenter_Summary`/
   `_Detail`, which every Exception Center category edits by recreating the
   whole body): never run two build/fix passes against the same environment
   concurrently — one CREATE silently overwrites the other's unrelated edits
   with no error. Sequence them, or re-pull `OBJECT_DEFINITION()` immediately
   before writing a new CREATE to confirm you're building on the truly-current
   version, not a stale read. (This bit twice in one session before this rule
   existed — see `sql/20-exception-center-reconciliation.sql`.)
See `.claude/skills/db-change-protocol/SKILL.md`.

---

## Hard rules (apply everywhere, all modules)

These come from real bugs already hit in this ERP. Violating them produces
numbers that look right and are wrong.

1. **Posted rows only:** `TicketMaster.Status IN ('POSTED','UPDATED')` whenever
   the general ledger is read.
2. **BranchCode is always `varchar`.** `'888'` = Head Office; branches are
   `'001'`–`'012'`. Never `Convert.ToInt32`, never trim into a lookup, never
   store display text (`'001-DAVAO'`) where the code belongs. This bug has bitten
   this system more than once.
3. **Account classification comes from `vw_AccountTree` + `RptMnemonicMap`,**
   never hardcoded account-code lists. Postability is decided by
   `ChartOfAccounts.AccountType = 'D'` (detail), never by `LevelNumber` — detail
   accounts exist at multiple levels.
4. **Date ranges:** `>= @From AND < DATEADD(DAY,1,@To)`. Never `BETWEEN` —
   `TicketDate` is `datetime` and a time component silently drops the last day.
5. **Signed amount:** Nature `'D'` → `Debit - Credit`; Nature `'C'` →
   `Credit - Debit`. Normal balances come out positive.
6. **Cross-branch balancing:** `MANUAL JV - CROSS-BR` and `EXP-MANUAL-CROSS-BR`
   balance across their shared `ReferenceNumber`, NOT per ticket. Any per-ticket
   balance check must exclude them (`RptMnemonicMap.IsCrossBranch = 1`).
7. **Internal movements** (`IT-*`, `JV-ICSETT*`, `RptMnemonicMap.IsInternal = 1`)
   are excluded from consolidated revenue/COGS — a stock transfer is not a sale.
8. **Gross vs net:** watch AP/EWT and discount legs. A −5% variance on a payment
   voucher is the fingerprint of an AP debit booked net of withholding instead
   of gross. Prior bugs in this family: `40103`-instead-of-`508`,
   hardcoded `40510` not in the chart.
9. **Every report route:** `[Authorize(Roles = "...")]`. Reporting is read-only;
   the SQL login (`rpt_reader`) has SELECT + EXECUTE only, DENY on writes.
10. **ADO.NET readers:** `GetOrdinal` + `IsDBNull`, never indexer-by-name per
    access. Fail loudly if a proc renames a column. Money → `decimal`, keys →
    string.

---

## Data-quality first

`sp_rpt_DataHealthCheck` exists and must stay green. Before trusting any new
report's numbers, run the relevant health check. When building aging, add the
subledger-vs-GL-control tie-out check (AR vs `101030101`, AP vs `201xx`). A
report that is present but wrong is worse than one that is missing.

**`dbo.PostingDateControl` is not safe to trust as a GL cutover cutoff**
(found 2026-09-29, see `sql/27`/`sql/28`). It was empty when `sql/12`/`sql/13`
were written, making `COALESCE(PostingDateControl.LatestPostingDate,
MAX(GLSummary.PostingDate))` a safe no-op — it is no longer empty, and every
row now reads the same date regardless of any individual account's real
GLSummary freeze point (it looks like a "period closed for posting" marker,
not "GL rollup is current" — the two got conflated). Any new proc needing a
GLSummary-migration-cutover cutoff should use
`MAX(GLSummary.PostingDate) WHERE Debits <> 0 OR Credits <> 0` scoped to the
specific account(s)/branch(es) it cares about — confirmed system-wide safe
(zero exceptions to `EndingBalance = BeginningBalance + Debits + Credits`
across all 56,180 live rows) — and should NOT reference
`PostingDateControl` at all until its actual intended meaning is confirmed
with the developer. `sp_rpt_Exec_Summary`, `sp_rpt_DataHealthCheck` (#12/#13),
and `sp_rpt_Exec_FlowBar` already carry this fix. `sp_rpt_BalanceSheetLiveWithDate`
and `sp_rpt_IncomeStatementLiveWithDate` were reverted to their pre-fix,
`PostingDateControl`-free-but-still-using-a-coarse-per-branch-cutoff state
after the broader per-account version broke whole-chart balance-sheet
footing by ~₱13.8M (see `sql/28`'s "PARTIAL REVERT" section) — fixing these
two properly (a carefully-computed shared per-branch cutoff, or per-account
cutoffs plus an automatic footing assertion) is open follow-up work, not done.

---

## Project layout

```
(repo root)
  CLAUDE.md                     this file
  .claude/
    db.local.md                 GITIGNORED — real credentials
    agents/                     the software team (subagents)
    skills/                     repeatable playbooks
  Controllers/  Models/  Data/  Services/  Views/  wwwroot/
  sql/                          all DDL scripts, reviewable + replayable
  docs/                         design briefs + previews per module
```

## Architecture

Standard MVC flow, one direction: `sp_rpt_*` proc → `Data/ReportRepository.cs`
(`IReportRepository` / `SqlReportRepository`, raw ADO.NET) → a `Services/*.cs`
per module (assembles the dashboard, applies short in-memory caching) →
`Controllers/*.cs` → Razor view. No EF, no AutoMapper — DTOs in `Models/` are
hand-written per proc result set.

Two repository read styles coexist by design:
- **Typed DTOs** (`Models/ReportModels.cs`, `AccountingModels.cs`) for
  dashboards with a fixed, known shape (Executive Overview, aging summaries).
- **Generic result sets** (`ReportRunResult` in `Models/ReportCenterModels.cs`)
  for the Report Center: `RunReportAsync` reads any `ReportCatalog` proc
  column-by-column (name + type tag + value) into `ReportResultSet` rows,
  rendered by one generic Grid/Statement/PivotStatement view instead of a
  typed class per report. Extending the Report Center means adding a
  `ReportDefinition` to `ReportCatalog` (`Models/ReportCenterModels.cs`), not
  a new controller action — see the `new-report-module` skill.

`FilterAwareController` (`Controllers/FilterAwareController.cs`) is the base
for controllers whose Period/Branch top-bar filter must persist across
navigation between modules (Executive ↔ Accounting): it (de)serializes
`FilterContext` to/from session under `core.filter`. `ReportCenterController`
does not inherit it — Report Center parameters are per-run, not session state.

Auth is a placeholder by design: `IUserAuthenticator` /
`ErpUserAuthenticator` (bottom of `Controllers/DashboardController.cs`) is a
stub gated by `DevAuth:Enabled` that must be replaced with a real lookup
against the ERP's user table before production use — see the comment block
there for what a real implementation must return (roles = department names:
Executive, Sales, Marketing, Operations, Accounting, Audit).

---

## The team (subagents in `.claude/agents/`)

- **db-report-engineer** — writes/reviews `sp_rpt_*`, applies the hard rules,
  owns the DB change protocol.
- **backend-dev** — controllers, services, repository, DTOs, auth.
- **frontend-dev** — Razor views, ECharts, the cold-storage design system.
- **accounting-reviewer** — the adversarial check: ties subledgers to GL,
  questions bucket logic, hunts gross-vs-net and sentinel bugs before they ship.

Delegate SQL to db-report-engineer and always run accounting-reviewer over any
new financial report before calling it done.

---

## Hey Jude must stay current — non-negotiable, same pass as the feature

"Hey Jude" (`Services/HeyJudeService.cs`, `Views/HeyJude/`) is the natural-
language front end over this portal's reports. It only ever knows what's
wired into it — the LLM behind it is a plain-English-to-parameters translator
over a fixed whitelist (`Models/HeyJudeModels.cs`'s `ReportIntent` enum), never
a free agent over the database. **Whenever a genuinely new report, dashboard
card, or embedded module ships — a new `sp_rpt_*` proc surfaced anywhere in
the app, not just a new finding inside an existing config-driven list —
update Hey Jude in the same pass**, not as a follow-up:

1. Add the intent to `ReportIntent` (`Models/HeyJudeModels.cs`).
2. Add it to `RunReportTool`'s `intent` enum and the system prompt's intent
   list (`Services/HeyJudeService.cs`) — explain when to use it and when NOT
   to (e.g. don't let it get confused with a similarly-named existing intent).
3. Add the case to `ParseRunReportArgs` and the `RunReportAsync` switch,
   calling the SAME `IReportRepository` method the dashboard already uses —
   never a fresh DB call, so every hard rule already proven in that proc
   (posted-only, signed amounts, disclosure caveats) carries straight through
   instead of being silently re-derived.
4. If the new report carries a caveat a user could misread at face value
   (see `sp_rpt_Exec_CashPosition`'s missing-opening-balance and PHP-only-
   despite-"USD"-labels disclosures), the chat answer must carry that same
   caveat, not just the dashboard UI — Hey Jude repeating a bare number
   without the caveat is exactly as misleading as the dashboard would be
   without it.
5. Update the unsupported-intent fallback answer and `Views/HeyJude/
   Index.cshtml`'s example-question hints so the new capability is
   discoverable, not just technically present.

**Exception, already handled by design, no action needed:** `exception_
center_summary` and `data_health_check` read whatever checks are CURRENTLY
configured in `ExceptionDefinition`/the health-check proc — a new check
inside one of those two shows up automatically with zero HeyJudeService
changes. This rule is about a genuinely new top-level report (a new proc,
a new dashboard card), not a new row inside one Hey Jude already knows how
to summarize.

Precedent: `InventoryByBranch` and `CashPosition` (added 2026-09-27, same
session the Cash & Bank Position card shipped) are the reference example —
see their case blocks in `HeyJudeService.RunReportAsync` for the caveat-
carrying pattern in #4 above.

## Design system — Modern Dark Admin Theme (authoritative)

Developer's global preference. Every module follows this. Write CSS/Tailwind to
match; do not reintroduce the earlier light theme.

**Palette**
- App background: deep slate `#0F172A`
- Surface / card background: `#1E293B`
- Primary text: `#F8FAFC`
- Secondary / muted text (labels, subtitles): `#94A3B8`
- Primary accent / brand: **Neon Blue `#3B82F6`**
- Borders & dividers: subtle `#334155`

**Risk & status colors** (behavioral rule kept from before — these override the
palette only where they apply):
- Money at risk / danger: `#F87171` (a red that reads on dark). RATIONED — use it
  ONLY for past due, over credit limit, negative variance. If everything is red,
  nothing is.
- Watch / warning: `#FBBF24` (amber)
- Good / positive: `#34D399` (emerald)
- Neutral pill: muted gray on `#334155`

**Typography**
- Clean sans-serif: Inter (or Roboto / system-ui fallback).
- Headers bold and crisp; smaller legible sizes for table data and sidebar links.
- All figures use tabular-nums so peso columns align. (Kept from before.)

**Layout & structure**
- Sidebar: fixed left nav, background DARKER than the content area (`#0F172A`
  sidebar against `#1E293B`-carded content, or a near-black `#121212`). Subtle
  lighter-gray hover states on menu items; active item carries the neon-blue
  accent (left border + tint).
- Top bar: minimalist — search, user profile, notifications, the period/branch
  filter, refresh.
- Content: card-based. Charts, tables, forms wrapped in rounded cards
  (border-radius 8–12px) with a subtle dark drop shadow
  `box-shadow: 0 4px 6px -1px rgba(0,0,0,.5)`.

**Components**
- Pill-shaped status badges (e.g. emerald bg + dark-emerald text for "Active";
  red family for risk).
- Buttons: slight brightness increase on hover.
- Inputs: dark background, subtle border that highlights to neon-blue `#3B82F6`
  on focus.
- ECharts: dark-theme axis/grid (`#334155` gridlines, `#94A3B8` labels), series
  in neon blue / emerald / amber; risk series in `#F87171`.
- Flow-bar unavailable stages render as an em-dash "pending", never as zero.

Full token set in `wwwroot/css/site.css`.
