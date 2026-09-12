---
name: statement-renderer
description: How to render hierarchical financial statements (Balance Sheet, Trial Balance, Income Statement pivot) in-browser from procs that return type + level columns. Use when building or changing the Report Center statement/pivot renderers.
---

# Statement Renderer

## The procs already give you the hierarchy
`sp_rpt_BalanceSheetWithDate`, `sp_rpt_TrialBalanceWithDate`, and
`sp_rpt_IncomeStatementAllBranchesPivot` return a **type** column and an
**indent-level** column. Do NOT rebuild hierarchy from account codes — read
these.

## First step: discover the real values
Run each proc once. Record the DISTINCT values of the type column and the range
of the level column. Build the value->class map from what is actually there.
Report those distinct values back before finalizing the map.

## Mapping
- level -> indent class: lvl0, lvl1, lvl2, lvl3 (progressive left padding).
- type -> emphasis:
  - section header: bold uppercase, no amount shown
  - detail: plain
  - subtotal: top rule, semibold
  - grand total: double underline, bold
- Negatives: parentheses + oxblood (--cut). Confirm whether the proc returns
  signed numbers or a sign/contra flag; detect accordingly.

## Grid vs Statement vs Pivot
- Grid reports: plain sortable table + totals footer.
- Statement: single amount column, the hierarchy above.
- PivotStatement (Income Statement): ONE COLUMN PER BRANCH, dynamic. Read the
  result schema at runtime: fixed leading columns (type, level, label) then treat
  every remaining column as a branch amount column. Never hardcode branch
  columns — adding a branch must not break it.

## Export
Excel export preserves indentation (use Excel indent levels). PDF is print-ready
with the same hierarchy. Codes stay text so leading zeros survive.
