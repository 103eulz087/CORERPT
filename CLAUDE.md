# CLAUDE.md — CORE Reporting Portal

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

- **Executive Overview** — BUILT and deployed. `sp_rpt_Exec_*` procs + Health
  Check + full MVC module.
- **Accounting module** — NEXT. AR/AP aging dashboard + Report Center over 7
  existing reporting procs. See `docs/brief-accounting-module.md`.
- Sales, Marketing, Operations, Audit — designed (see `docs/`), not built.

---

## Database connections

Credentials are NOT in this file. They live in `.claude/db.local.md`, which is
gitignored. Read that file for the actual server/user/password.

- **Development DB (default): `CORECSERP_002_DEV`** on the test server.
  All new/altered tables, stored procedures, functions and views go here FIRST,
  by default, without asking.
- **Staging DB: `CORECSJFC2026_STAGING`** on the same server.
  NEVER apply schema changes (tables, SPs, functions, views) to staging without
  explicitly asking the developer first and getting a yes. Reads are fine;
  writes/DDL require confirmation every time.

The developer can supply real data into DEV since a live system already exists.

### DB change protocol (non-negotiable)
1. New or altered DDL → `CORECSERP_002_DEV` by default.
2. Before touching `CORECSJFC2026_STAGING` with any DDL, STOP and ask.
3. Every reporting object is `sp_rpt_*`. It only reads. If a proc would INSERT/
   UPDATE/DELETE base tables, that is a bug — stop and flag it.
4. Save every DDL script to `/sql/` in the repo so changes are reviewable and
   replayable. Never apply a change that exists only as an ad-hoc query.
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

---

## Project layout

```
CoreReporting/
  CLAUDE.md                     this file
  .claude/
    db.local.md                 GITIGNORED — real credentials
    agents/                     the software team (subagents)
    skills/                     repeatable playbooks
  Controllers/  Models/  Data/  Services/  Views/  wwwroot/
  sql/                          all DDL scripts, reviewable + replayable
  docs/                         design briefs + previews per module
```

## The team (subagents in `.claude/agents/`)

- **db-report-engineer** — writes/reviews `sp_rpt_*`, applies the hard rules,
  owns the DB change protocol.
- **backend-dev** — controllers, services, repository, DTOs, auth.
- **frontend-dev** — Razor views, ECharts, the cold-storage design system.
- **accounting-reviewer** — the adversarial check: ties subledgers to GL,
  questions bucket logic, hunts gross-vs-net and sentinel bugs before they ship.

Delegate SQL to db-report-engineer and always run accounting-reviewer over any
new financial report before calling it done.

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
