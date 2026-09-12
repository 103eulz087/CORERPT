---
name: aging-sp-pattern
description: How to build a correct AR or AP aging stored procedure for this portal. Use when creating sp_rpt_AR_Aging, sp_rpt_AP_Aging, or any bucketed aging report.
---

# Aging SP Pattern

## Confirmed facts (this ERP)
- AR open balance: `TransactionChargeSales` (customer id, Balance, invoice).
  Balance is the REMAINING open amount after partial payments (already net).
- AP open balance: `APAccounts.Balance` (also remaining).
- Age from INVOICE DATE. Fixed buckets: Current(0) / 1-30 / 31-60 / 61-90 / 90+.
- AR branch comes from the CUSTOMER master (TransactionChargeSales has no branch
  of its own). "Branch" = customer's HOME branch (who owes), not selling branch.
  Join invoice -> customer to get the branch and filter on that.

## Before writing: read the real schema
Connect to CORECSERP_002_DEV and confirm exact column names for:
invoice date, customer/supplier id, Balance, invoice no; the customer master
table + its branch column + the join key; the credit-limit and terms columns +
their table; how APAccounts gets its branch (direct column vs supplier join).
Report these back before coding.

## Parameter shape (match the Exec procs)
`@AsOfDate date`, `@BranchCodes varchar(200) = NULL` (NULL/empty = all),
STRING_SPLIT branch filter into a temp table.

## Bucketing
`DATEDIFF(DAY, InvoiceDate, @AsOfDate)` -> CASE into the five buckets.
Only open items: `Balance > 0`. Guard NULL/future invoice dates (they cannot be
aged — surface them in the health check, do not silently bucket them).

## Output
Result set 1: one row per customer/supplier — code, name, five bucket sums,
total, credit limit, terms, exposure% (total/limit), oldest age in days.
Result set 2 (or a rollup): bucket totals for the chart.
Explicit CAST on every column.

## Correctness (hand to accounting-reviewer after)
- Tie AR total to GL 101030101, AP total to 201xx as of @AsOfDate. Report gaps.
- Watch credit balances that would net buckets negative — exclude or show as a
  separate unapplied-credits line, developer's call.
- Comment the DSO formula if this proc feeds DSO.
