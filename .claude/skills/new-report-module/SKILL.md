---
name: new-report-module
description: End-to-end recipe for adding a new department module or a new report to the CORE Reporting Portal, wiring SP -> repository -> service -> controller -> view with the right roles. Use when starting any new module (Sales, Marketing, Operations, Audit) or adding a report.
---

# New Report / Module Recipe

Follow in order. Delegate each layer to the right agent.

## 1. Design exists first
Confirm there is a design brief/preview in `docs/` for this module. If not, the
shape should be agreed in chat before building. Don't invent dashboards.

## 2. SP layer  (agent: db-report-engineer)
- Read real schema from CORECSERP_002_DEV. Report columns back.
- Write `sp_rpt_<Area>_<Report>` following the hard rules in CLAUDE.md.
- Save to `/sql/`. Smoke test. If financial, queue accounting-reviewer.

## 3. Repository  (agent: backend-dev)
- Add IReportRepository method + SqlReportRepository impl. GetOrdinal readers.
- Add DTO(s), one per result set.

## 4. Service  (agent: backend-dev)
- Per-dashboard service with 2-min cache keyed on filter, concurrent proc calls.
  Report Center reports usually don't need caching (parameterized, on-demand).

## 5. Controller  (agent: backend-dev)
- Thin actions. Dashboard -> view. *Data -> thin JSON for polling. Report Center
  -> config-driven engine, not a hand-built page per report.
- `[Authorize(Roles="...")]` on every route. Get roles right per module:
  - Executive: Executive
  - Accounting/Report Center/financial statements: Accounting, Audit, Executive
  - Sales: Sales, Executive
  - Operations: Operations, Executive
  - Audit: Audit, Executive

## 6. View  (agent: frontend-dev)
- Reuse the card grid, KPI tiles, ECharts config, cold-storage CSS.
- Oxblood only for money at risk. Unavailable values render as pending, not zero.
- Add the module's sidebar section, scoped to its roles.

## 7. Review  (agent: accounting-reviewer, for anything financial)
- Tie-outs, signs, sentinels, gross-vs-net. Green means verified.

## 8. Health
- If the module introduces a new data source, add a health check for it
  (nulls, orphans, subledger-vs-GL tie-out) and keep it green.
