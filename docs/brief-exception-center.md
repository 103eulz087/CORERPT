# Claude Code Brief — Exception Center (Business-Process Red Flags)

New module for **Management + Audit only**. Distinct from `sp_rpt_DataHealthCheck`:
that proc verifies ledger integrity (does the math tie out). This module detects
**business-process exceptions** — skipped steps, control overrides, stale items,
things a human should look at. Both belong in the portal; don't merge them.

## Architecture — config-driven, like the Report Center

Do NOT build one hardcoded page per category. Each exception is a row in a
definition table/config:

```
ExceptionCode | Category | Title | Severity (Critical/Warning/Info)
            | ProcName | HasDrillDown | DrillDownRoute
```

One aggregator proc (`sp_rpt_ExceptionCenter_Summary`) calls or UNIONs each
individual exception check and returns: category, title, severity, count,
value-at-risk (peso, nullable), as-of timestamp. The landing page is a grid of
category cards (mirrors the Report Center's card-grid pattern) showing live
counts; clicking a card drills into that exception's detail rows.

This mirrors `sp_rpt_DataHealthCheck`'s shape (already built) — reuse that
proc's result pattern (CheckName, Severity, Findings, ValueAtRisk) so the UI
component that renders the Health Check page can be reused here with a
different data source, not rebuilt.

## Access

`[Authorize(Roles = "Executive,Audit")]` on every route in this module. Not
Accounting, not department heads — Management + Audit only, per developer.

## Before writing ANY check — read the real schema, report back

For every category below, first locate the actual tables/columns involved and
report them back. Do not guess table names. This module touches parts of the
schema not yet used elsewhere in the portal (inventory, PO, sales orders,
voucher/check tables) — expect to spend real time here before writing SQL.

---

## Checks to build, by category

### Segregation of Duties (build first — cheapest, schema already known)
- **Same preparer/approver.** `TicketMaster` has `EnteredBy`, `CheckedBy`,
  `ApprovedBy`. Flag tickets where the same user appears in 2+ of these fields.
  No new schema discovery needed — this can be written immediately.
- **After-hours postings.** Postings with a system-entry timestamp outside
  normal business hours (confirm whether `TicketMaster`/`TicketDetails` or an
  audit/created-at column carries a real timestamp vs just `TicketDate` as a
  date-only value — this determines if the check is even possible).

### Inventory
1. Zero-cost items currently in inventory (on-hand qty > 0, unit cost = 0 or NULL).
2. Near-expiry / expired items — developer confirmed expiry/production date IS
   captured on receiving. Bucket similarly to aging: expired / ≤7 days /
   8–30 days. Reuse aging-bucket presentation pattern from AR/AP aging.
3. Item conversion variance — CONFIRM WITH DEVELOPER what "conversion" means in
   this system (UOM conversion e.g. box→kg, or butchering/yield variance from
   primal cut to portion cuts) before writing the check; the detection logic
   differs significantly between the two.
4. Stock transfers shipped but not yet received, aged by days in transit.
5. Stock transfers received with a quantity variance vs shipped — flag as
   needing receive-completion, return, or loss declaration. This is a
   two-sided reconciliation (shipped qty vs received qty per transfer); confirm
   the transfer table structure supports this comparison.
6. **Added:** negative on-hand quantity (data integrity red flag, cheap to add
   alongside #1 since it's the same inventory-position source).

### Sales
1. OR/SI/DR sequence gaps (numbering skips) — per branch, per document series.
2. Unconfirmed orders aged beyond a threshold (confirm the threshold with
   developer, e.g. > 24h unconfirmed).
3. Vatable items with zero VAT calculated (mismatch between item's VAT-ability
   flag and the VAT amount actually posted).
4. Customer credit memos — count + value, by customer and by agent (ties to the
   Agent Scorecard if that module is built — same RptMnemonicMap CM-CLIENT-*
   family already classified).
5. Returned orders — count + value.
6. **Added:** orders that exceeded the customer's stored credit limit at the
   time the order was placed (credit limits are already confirmed to exist per
   the Accounting module work).
7. **Added:** manual price overrides below cost or below a stored floor price
   — CONFIRM WITH DEVELOPER whether cost-at-time-of-sale or a floor price is
   actually captured; do not build this one if the data doesn't exist, report
   back instead.

### Purchasing
1. Pending / for-approval PO count, aged by days pending.
2. Approved POs pending receipt, aged by days since approval.
3. FOR CONFIRMATION POs.
4. **Added:** over-receipt — received quantity exceeds ordered quantity on a
   PO line.
5. **Added:** receiving posted with no PO reference at all (if the schema
   permits this — confirm).

### Vouchering
1. Cancelled checks — reuse/extend `sp_CancelledChequesCS` if it already
   returns what's needed, don't duplicate logic.
2. Reversals — count + value.
3. **Added:** duplicate check numbers within a bank account.
4. **Added:** duplicate supplier-invoice numbers across payment vouchers
   (double-payment risk).
5. **Added:** checks prepared but not released/cleared beyond N days
   (confirm the check-status lifecycle in the schema first).

**Cross-check overlap, disclosed:** `VOU-CANCELLED-CHECKS` and
`VOU-REVERSED-VOUCHERS`/`EXP-REVERSALS` (Post Expense) structurally overlap —
`sp_CancelledChequesCS` writes `CheckVoucher.isErrorCorrect` and inserts the
matching `PaymentReversalAudit` row in the same transaction, so every
check-type cancellation lands in all of them at once (confirmed live: DEV's 3
cancelled checks are a strict subset of `VOU-REVERSED-VOUCHERS`'/
`EXP-REVERSALS`' 4 findings). No current dashboard tile sums across these
codes, so this is not a bug today, but a future rollup/KPI/Excel export must
de-duplicate by VoucherID before summing `ValueAtRisk`/`Findings` across them.
See `sql/16-exception-center-vouchering-postexpense.sql` header for the full
trace.

### Post Expense
1. Reversals / edits — the June work already built a six-column
   ExpenseSummary tracking schema and edit-tracking; reuse that data source
   rather than rebuilding it. Cross-reference against the existing "high edit
   rate" pattern from the earlier Audit design.

### AR
1. Payment reversals — reuse `sp_ReversePaymentClient`'s data trail; that SP
   was already debugged extensively in June, the audit trail should exist.
2. **Added:** unapplied credit balances (customer advances/overpayments sitting
   open beyond N days) — related to the credit-balance risk flagged in the
   AR aging module; if that module already surfaces this, link to it rather
   than duplicating.

### Master Data (new category)
1. **Added:** duplicate customer or supplier records — same TIN, or
   near-identical name (confirm what uniqueness fields exist before deciding
   match logic — exact TIN match is safe and cheap; fuzzy name matching is a
   bigger, separate task, don't build it unprompted).
2. **Added:** inactive/deactivated customers or suppliers with transactions
   posted after their deactivation date (if such a flag/date exists).

---

## Build order

1. Segregation of duties (same preparer/approver) — ship first, zero schema
   discovery needed, proves the config-driven architecture end to end.
2. Vouchering + Post Expense + AR reversals — mostly reusing SPs/data trails
   that already exist from June's debugging work.
3. Sales — sequence gaps, unconfirmed orders, VAT mismatch, credit memos,
   returns, credit-limit breach.
4. Purchasing — pending/approval counts, over-receipt.
5. Inventory — zero-cost, near-expiry, negative on-hand (straightforward);
   conversion variance and transfer reconciliation last (need developer
   clarification first, flagged above).
6. Master data duplicates — last, lowest urgency.

At each step, report back the real schema found and any check from the list
above that turns out not to be buildable with current data — don't silently
skip it, name it so the developer can decide whether to start capturing that
data going forward.

## Hand to accounting-reviewer

For any exception involving pesos (credit memos, over-receipt value, unapplied
credits, price overrides), verify the value-at-risk figure against a hand-
checked sample before trusting it on the dashboard.
