/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER (Build Order Step 3)
   Target: CORECSERP_002_DEV only (never staging without asking).

   Scope of THIS script: the SALES category ONLY, per the brief's build order.
   Segregation of Duties (sql/15), Vouchering + Post Expense (sql/16), and AR
   (sql/17) are already shipped and reviewed and are NOT touched here. This
   script only ADDS new ExceptionDefinition rows and new IF @ExceptionCode
   branches to the two existing shared procs, following the exact same
   pattern as all three prior passes. Purchasing/Inventory/Master Data are
   explicitly OUT of scope for this pass (later build-order steps).

   This category required more live-schema investigation than any prior pass
   — the brief's own warning ("this module touches parts of the schema not
   yet used elsewhere... expect to spend real time here") was accurate. Every
   table/column below was read from CORECSERP_002_DEV live before being used;
   nothing here is guessed from a table/column name alone.

   ----------------------------------------------------------------------------
   OVERALL SALES-SUBSYSTEM SCHEMA MAP (confirmed live, 2026-09-23)
   ----------------------------------------------------------------------------
   dbo.TransactionSales / TransactionSalesDetails / OrderDetails / ShipmentOrder
     / POSSalesSummary / ManipOR — ALL 0 ROWS in CORECSERP_002_DEV today. These
     look like a POS/retail-counter sales path this ERP supports in principle
     but does not currently use for this business (B2B wholesale to hotels/
     restaurants, not walk-in retail). Not used by anything below.

   dbo.DeliverySummary (2,120 rows) / dbo.DeliveryDetails (5,097 rows) — THE
   real sales order + delivery workflow for this business. DeliverySummary:
     DeliveryNo varchar(20) (an internal running counter — dbo.deliveryno is a
       literal 1-row "next number" generator table, same pattern as
       dbo.conversionnumber/dbo.badorderno referenced in sql/15/16),
     PONumber varchar(20) (confirmed live = TransactionChargeSales.ReferenceNo
       for DELIVERED/RETURNED rows — 2,015 of 2,025 DELIVERED and 26 of 26
       RETURNED rows bridge this way; this is the SAME KIND of
       TicketMaster.ReferenceNumber = TransactionChargeSales.ReferenceNo
       "the bridge" already established in sql/14, just one hop earlier in
       the sales lifecycle — DeliverySummary.PONumber IS the eventual
       invoice's ReferenceNo, not a customer's own purchase-order number
       despite the column name),
     ReferenceNumber varchar(20) (a DIFFERENT internal number, NOT the bridge
       — confirmed live it does NOT match TransactionChargeSales.ReferenceNo;
       not used below),
     InvoiceNo varchar(20), BranchCode varchar(20) (the SELLING branch, same
       convention as TransactionChargeSales.BranchCode — never confused with
       a customer's home branch per the brief's own caveat),
     Status varchar(50) — confirmed LIVE VALUES: DELIVERED (2,025), FOR
       DELIVERY (24), PENDING (45), RETURNED (26). THIS is the genuine
       order-confirmation workflow the brief asked to find for Sales check #2
       — PENDING = order placed, not yet confirmed for dispatch; FOR DELIVERY
       = confirmed/dispatched, awaiting completion; DELIVERED = fulfilled;
       RETURNED = came back. EffectivityDate/DateAdded (both `date`, no time
       component) plus PreparedBy, isSettled, TotalItemReturned/TotalItemSold.
   DeliveryDetails: SeqNo, DeliveryNo, PONumber, ReferenceNumber, ProductNo,
     ProductName, QtyDelivered, ActualQty, Cost, SellingPrice, Status
     (line-level: DELIVERED/FOR DELIVERY/PENDING, 4,732/210/155), isVat,
     isReturned, isCancelled, DateTimeAdded/DateTimeUpdated — DATETIME, and
     CONFIRMED LIVE to carry genuine time-of-day (0 of 5,097 rows sit at
     midnight, unlike TicketMaster.TicketDate in sql/15) — this is what makes
     an HOUR-level "unconfirmed order aged beyond N hours" check possible at
     all for Sales, where it was NOT possible for the SOD after-hours check.

   dbo.TransactionChargeSales (5,063 rows) / TransactionChargeSalesDetails
     (7,056 rows) — the AR/invoicing subledger already used throughout this
     portal (sql/05, sql/14). Re-confirmed here: InvoiceNo is a per-branch,
     letter-coded, free-text field (e.g. '001'->'D_', '004'->'C-', '888'->'J'
     mostly, plus DR/DM/CM/AUDIT- tag variants for a minority of rows) — see
     SALES-DOC-SEQ-GAPS section below for why this does NOT support the
     brief's numbering-gap check. TransactionChargeSalesDetails.Type/
     TransCode carries a clean, already-classified line-type taxonomy per
     invoice: 'SALES VAT'/'SI-VAT', 'SALES VAT EXEMPT'/'SI-VATEX', 'VAT OUTPUT
     TAX'/'SI-VAT-OUT', 'COST OF SALES VAT'/'COGS-VAT', 'COST OF SALES
     VATEX'/'COGS-VATEX' — each SALES-type line also carries Cost and
     SellingPrice per unit (confirmed live, used by SALES-BELOW-COST below).

   dbo.Products (10,623 rows, ProductCode varchar(50)) — THE item master.
     Confirmed live: NOT dbo.GenInventoryItems (only 4 columns: SequenceNumber/
     ItemCode/Description/ItemCategory — no VAT flag, no pricing, effectively
     a bare lookup, not used anywhere in the sales flow below). Products.isVat
     bit is the item's VAT-ability flag (225 vatable / 2,115 non-vatable of
     2,340 products — most of this company's meat/frozen-goods SKUs are
     VAT-exempt agricultural products, a handful of add-on items like fries/
     seasonings are vatable). Confirmed live 100% join match (52,125/52,125)
     from TransactionChargeSalesDetails.Product = Products.ProductCode for
     every SALES-type line — this is a reliable, complete join, not a
     partial/best-effort one.

   dbo.RptMnemonicMap — re-confirmed live (not re-derived): CM-CLIENT-VAT /
     CM-CLIENT-VATEX (Family SALES_ADJ) are the already-classified client
     credit-memo mnemonics. Only CM-CLIENT-VATEX has live rows today (26); the
     check below is written against the Mnemonic LIKE 'CM-CLIENT-%' PATTERN
     (joined through RptMnemonicMap, not two hardcoded literal strings) so a
     future CM-CLIENT-VAT posting is picked up automatically without a code
     change — same spirit as Hard Rule #3 (classification via RptMnemonicMap,
     never a hardcoded list), applied to Mnemonic membership the same way
     sql/14 applies it to AncestorCode membership.

   dbo.ReturnedOrderSummary (96 rows) / ReturnedOrderDetails (178 rows) — THE
     returned-orders table for Sales check #5. TotalAmount (header) confirmed
     live to tie EXACTLY to SUM(SellingPrice*QtyDelivered) from
     ReturnedOrderDetails for every sampled header — a reliable, already-
     rolled-up value column, no re-derivation needed. TicketRefNoVAT /
     TicketRefNoVATEX varchar(10) — CONFIRMED LIVE to be the bridge to
     dbo.TicketMaster.TicketNumber for the GL credit-memo posting this return
     produced, when one exists.

   dbo.ClientLedger (5,178 rows, 1,254 distinct AccountKey=CustomerKey) — a
     genuine RUNNING-BALANCE AR ledger: BeginningBalance/Debit/Credit/
     EndingBalance per row, ordered by TRN_SEQ_NO per customer, TransCode
     values BF (Balance Forward Aging, 3,011 rows, pre-existing balances
     carried in from before this table's day-to-day feed started) + SI-VAT/
     SI-VATEX/CM-CLIENT-VATEX/OR-COLL/OR-OVERPAY/OR-EWT/OR-EWT-DISC/OR-DISC/
     SVC-REVENUE(-REV) (the live day-to-day feed, 2026-08-01 onward).
     Confirmed live: 5,212 of 5,216 TransactionChargeSales rows (99.9%) have a
     matching ClientLedger row via (AccountKey=CustomerKey, InvoiceNo) — this
     is a reliable, comprehensive per-customer running balance, NOT a sparse/
     periodic snapshot table, which is what makes the point-in-time
     reconstruction in SALES-CREDIT-LIMIT-BREACH below possible at all (this
     ERP has essentially no other historical/point-in-time balance source —
     TransactionChargeSales.Balance is a live "as of right now" field only).

   ----------------------------------------------------------------------------
   CHECK 1 — SALES-DOC-SEQ-GAPS (OR/SI/DR numbering) — INVESTIGATED IN DEPTH,
   NOT BUILDABLE, NOT BUILT (per the brief's explicit instruction: name it,
   don't force it — same treatment as after-hours-postings in sql/15 and the
   Post-Expense edit-rate check in sql/16)
   ----------------------------------------------------------------------------
   Searched sys.objects and INFORMATION_SCHEMA for any dedicated numbering/
   series table (NumberSeries, DocSequence, etc.) — none exists. The only
   "next number" generator tables found (dbo.deliveryno, dbo.badorderno,
   dbo.conversionnumber — all confirmed single-row counters) generate this
   ERP's own INTERNAL reference numbers (DeliverySummary.DeliveryNo,
   TicketMaster-adjacent order numbers), not a printed OR/SI/DR document
   series a BIR audit would care about.

   "OR" (Official Receipt): the only candidate is dbo.PaymentHeader.CRNo
   varchar(30). CONFIRMED LIVE this is NOT a controlled sequential field —
   sampled PaymentHeader rows show the literal value '5256' reused across at
   least 3 DIFFERENT PaymentHeaderIDs (4280, 4271, 4273) alongside other
   short, non-monotonic values ('82556', '0852', '562354') with no
   correlation to PaymentDate. This is free-text manual entry, not a
   system-enforced OR series. A gap/duplicate check built on it would be
   meaningless (duplicates are already routine, "gaps" undefined for a
   non-sequential field). dbo.ManipOR exists but has 0 rows (unused).

   "DR" (Delivery Receipt): no standalone DR number/table exists. "DR" only
   appears as a SUBSTRING TAG embedded inside TransactionChargeSales.InvoiceNo
   for a minority of rows (e.g. 'DR 2608-01', 'C-DR ', 'X-DR-', confirmed live
   across BranchCode 888/004/008/010, well under 100 rows total) — a
   free-text convention some branches use to mark a delivery-receipt-in-lieu-
   of-invoice transaction, not a distinguishable, independently-numbered
   series with its own gap-detectable population.

   "SI" (Sales Invoice) via TransactionChargeSales.InvoiceNo — the one
   candidate with real volume and a real per-branch letter-coded numeric
   suffix (e.g. branch 004 = 'C-####', branch 888 mostly = 'J######').
   Built and tested a full numeric-suffix gap-detection query against this
   field (dominant per-branch prefix, LAG-based consecutive-number gap scan)
   BEFORE deciding to ship it. Results, confirmed live:
     - Across full history (2014-2026), the numeric suffix does NOT correlate
       with TransactionDate AT ALL for large stretches — e.g. BranchCode 888
       prefix 'J': TicketNumber-adjacent suffix 702 dated 2014-11-02 is
       immediately followed (in numeric order) by suffix 36028 dated
       2025-12-09, which is immediately followed by suffix 100530 dated
       2014-07-01 — the date goes BACKWARD by 11 years as the number goes UP.
       This pattern repeats at multiple points across every branch's series.
       This is unambiguous evidence of a historical bulk migration/reused
       numbering pool, not a live chronological series — a "gap" computed
       across it (one incident measured 221,606 "missing" numbers) is a
       migration artifact, not a real compliance finding.
     - Restricting to the confirmed-live period (TransactionDate >= 2026-01-01,
       where the date-vs-number correlation is at least monotonic/
       chronological) STILL produces large, non-trivial "gaps" — e.g.
       BranchCode 004 prefix 'C-': suffix 41476 (2026-01-15) to 44031
       (2026-03-31), 2,554 "missing" numbers over 2.5 months. Traced this:
       TransactionChargeSales captures ONLY charge/AR (credit) sales.
       TransactionSales/POSSalesSummary (this ERP's cash/POS sales path) are
       confirmed 0 rows in DEV today. If this business's branches also issue
       invoices under the SAME physical numbering pool for cash sales (a
       normal practice — one invoice booklet serves all payment types), then
       every cash sale invoice consumes a number this table never sees,
       making every "gap" computed from TransactionChargeSales alone
       indistinguishable from an invoice legitimately issued to a cash
       customer. There is no complementary live cash-sales table in this DEV
       data to union in and close that gap.
   CONCLUSION: neither OR nor DR has a genuine, gap-detectable series in this
   schema, and the one SI candidate cannot be reliably gap-checked from
   TransactionChargeSales alone without either (a) a live cash-sales feed
   this ERP doesn't currently populate, or (b) confirmation from the
   developer that InvoiceNo numbering is dedicated to charge sales only (not
   yet confirmed). Building this check today would produce large, confident-
   looking "missing invoice" alerts that are actually either migration noise
   or ordinary cash sales — exactly the "present but wrong" failure mode
   CLAUDE.md warns against. NOT BUILT. No ExceptionDefinition row seeded.
   REVISIT once the developer confirms (1) whether InvoiceNo is charge-sales-
   only or shared with cash sales, and (2) whether OR/DR are meant to be
   captured as real controlled series anywhere going forward.

   ----------------------------------------------------------------------------
   CHECK 2 — SALES-UNCONFIRMED-ORDERS-AGED — BUILT
   ----------------------------------------------------------------------------
   "Unconfirmed" = DeliverySummary.Status = 'PENDING' (order placed, not yet
   moved to FOR DELIVERY). Aged from the order's PLACED-AT timestamp — the
   EARLIEST DeliveryDetails.DateTimeAdded across that DeliveryNo's lines
   (genuine time-of-day, see schema map above), falling back to
   CAST(DeliverySummary.DateAdded AS datetime) (midnight) only for the rare
   header with no detail rows at all (none observed live today, but handled
   defensively) — to a caller-controlled as-of reference (@AsOfDate when
   supplied, else the real GETDATE() wall-clock "now", NOT the date-only
   @StaleAsOf variable sql/16/17 use for their DAY-granularity aging checks —
   an hour-level threshold needs real sub-day precision, which a `date`
   parameter cast to midnight would silently destroy for same-day orders).

   THRESHOLD PLACEHOLDER: @UnconfirmedOrderHours = 24, exactly the example
   the brief itself proposes ("e.g. > 24h unconfirmed"). NOT the developer's
   real house number — REVISIT once confirmed, same treatment as every other
   placeholder in this module.

   VALUE-AT-RISK DATA-QUALITY FINDING (real, not hidden): ValueAtRisk is
   SUM(DeliveryDetails.SellingPrice * QtyDelivered) per flagged header.
   Confirmed live: ALL 45 currently-PENDING orders' DeliveryDetails lines
   carry SellingPrice = 0.00 (0 of 131 lines across PENDING+FOR DELIVERY have
   a nonzero SellingPrice) — pricing is evidently populated later in this
   ERP's workflow (at/after invoicing), not at order-placement time. This
   check's ValueAtRisk will therefore show 0.00 against current DEV data.
   That is NOT a bug in this query — it is a genuine schema/workflow fact
   worth flagging to the developer: today, an open sales order carries no
   visible peso value anywhere in the schema until it is invoiced, which
   means Management/Audit cannot currently see "how much money is sitting in
   unconfirmed orders" even though the COUNT is fully visible and real (45
   today, all already older than the 24h placeholder).

   SCOPE NOTE: DeliverySummary.Status = 'FOR DELIVERY' (24 rows today) is a
   related but DISTINCT concept — an order that HAS been confirmed and is now
   awaiting dispatch completion, not an "unconfirmed" order. Deliberately not
   folded into this check (a future "dispatch delay" check is a natural
   sibling, out of scope here per the brief's literal wording).

   SEVERITY: Warning. A pending order is routine operational backlog, not a
   control failure — but 45 orders sitting PENDING for weeks (the oldest
   observed today is ~40 days old, entered 2026-09-10/11 with an
   EffectivityDate as early as 2026-08-01) is a real fulfillment-process
   signal worth surfacing, hence not Info.

   ----------------------------------------------------------------------------
   CHECK 3 — SALES-VATABLE-ZERO-VAT — BUILT
   ----------------------------------------------------------------------------
   Joins TransactionChargeSalesDetails.Product = Products.ProductCode
   (confirmed 100% match rate, see schema map) and flags every SALES-type
   line where Products.isVat = 1 (the item master says this item IS vatable)
   but the line was posted with Type = 'SALES VAT EXEMPT' (TransCode
   'SI-VATEX') — i.e. the actual GL/subledger posting treated a vatable item
   as VAT-exempt, meaning $0 output VAT was calculated on a sale that should
   have carried it. (Checked the reverse direction too — non-vatable item
   posted as 'SALES VAT' — 0 rows live today; not flagged since it's not
   what the brief asks for, but the logic keeps both directions easy to spot
   in the header for a future pass if the developer wants over-taxation
   flagged too.)
   CONFIRMED LIVE (2026-09-23): 75 lines / 5 invoices / 1 product (AVIKO
   SHOESTRING FRIES (1KG), ProductCode 12050) across BranchCode 888,
   2026-08-06 to 2026-08-06 (all 5 invoices same day, batched) — total sales
   amount misclassified ₱114,000.00. EstimatedVATShortfall shown in the
   DETAIL only (ROUND(TotalAmount / 1.12 * 0.12, 2), i.e. back out the 12%
   VAT that a VAT-INCLUSIVE selling price should have carried) — labeled
   ESTIMATED because it is a derived number, not a figure actually posted
   anywhere in the GL; ValueAtRisk on the SUMMARY card is the real posted
   SALES AMOUNT at risk (₱114,000.00), not the derived VAT estimate, to keep
   the summary tile grounded in an actual ledger figure per this module's own
   discipline (see sql/16/17's insistence on real posted amounts over
   re-derived ones).
   SEVERITY: Critical. A VAT-ability misclassification is a tax-compliance
   exposure (potential BIR assessment/penalty on the shortfall, plus
   understated Output VAT in whatever return period these fall in) — this is
   the kind of error CLAUDE.md's "gross vs net" family of bugs describes,
   just on the sales side instead of AP/EWT.

   ----------------------------------------------------------------------------
   CHECK 4 — SALES-CM-CLIENT (customer credit memos, by customer + agent) —
   BUILT, fully via the already-established classification/bridge pattern
   ----------------------------------------------------------------------------
   TicketMaster.Mnemonic classified via RptMnemonicMap (Mnemonic LIKE
   'CM-CLIENT-%', not hardcoded to the two known literal values — see schema
   map), posted-only (Status IN ('POSTED','UPDATED')), bridged to
   TransactionChargeSales via ReferenceNumber = ReferenceNo — THE SAME BRIDGE
   sql/14's Agent Scorecard already validated for this exact mnemonic family
   (100% match, 26/26, re-confirmed live here) — then to Customers for
   CustomerName and AgentLabel (Customers.AccountOfficer, same
   ISNULL(NULLIF(LTRIM(RTRIM(...)),''),'UNASSIGNED') normalization sql/14
   uses, current-agent/all-time attribution, same disclosed limitation:
   misattributes if the account officer has since changed).
   VALUE: the AR-control-account leg of the credit memo ticket
   (TicketDetails joined to vw_AccountTree WHERE AncestorCode = '101030101' —
   the SAME classification idiom sql/01/05/08/09 already use for the AR
   control account, never a raw hardcoded WHERE AccountCode = '101030101' on
   TicketDetails directly — this satisfies Hard Rule #3 the same way every
   other AR-control reference in this codebase already does), shown as
   Credit-Debit (a positive "value of credit given" magnitude for display,
   deliberately NOT the account's own Nature-'D' signed convention which
   would render negative — documented here, not silently chosen, per Hard
   Rule #5's spirit). Confirmed on a hand-checked example (TicketNumber 7237,
   BranchCode 888): Sales(401) debited 9,620.00 / AR(101030101) credited
   9,620.00 — a clean 2-leg VATEX credit memo, AR leg used as ValueAtRisk.
   CONFIRMED LIVE (2026-09-23): 26 tickets, ValueAtRisk = ₱1,476,101.10.
   DATA-QUALITY / OVERLAP FINDING (disclosed, not fixed, same treatment as
   sql/16's VOU-CANCELLED-CHECKS/VOU-REVERSED-VOUCHERS overlap): ALL 26
   CM-CLIENT-VATEX tickets today trace back to a dbo.ReturnedOrderSummary row
   via TicketRefNoVATEX — i.e. in THIS data, every GL credit memo originated
   from a returned-order event. The Detail result for SALES-RETURNED-ORDERS
   (check 5) surfaces a HasGLCreditMemo flag per return row precisely so a
   reviewer can see this relationship directly rather than assume the two
   checks are counting different things. A future "total customer credit
   risk" rollup must NOT sum SALES-CM-CLIENT and SALES-RETURNED-ORDERS
   ValueAtRisk together without deduplicating — SALES-CM-CLIENT's 26/₱1.48M
   is a SUBSET of SALES-RETURNED-ORDERS' 96/₱3.41M, not an independent
   population (see check 5 below for the reverse direction and the more
   interesting finding: 70 of 96 returns have NO GL credit memo at all).
   SEVERITY: Warning. Same reasoning as VOU-REVERSED-VOUCHERS/AR-REVERSED-
   PAYMENTS elsewhere in this module — a credit memo is a normal, legitimate
   correction mechanism; this check exists to monitor volume/concentration by
   customer/agent, not to allege wrongdoing on sight.

   ----------------------------------------------------------------------------
   CHECK 5 — SALES-RETURNED-ORDERS (count + value) — BUILT
   ----------------------------------------------------------------------------
   Straight read of dbo.ReturnedOrderSummary, windowed on DateAdded (`date`,
   no time component — this table predates the DeliveryDetails timestamp
   granularity used in check 2). TotalAmount used as-is (confirmed live to
   tie exactly to SUM(ReturnedOrderDetails.SellingPrice*QtyDelivered) — see
   schema map; no re-derivation needed or attempted). CONFIRMED LIVE
   (2026-09-23): 96 rows, ValueAtRisk = ₱3,405,042.08 (91 of 96 rows have a
   nonzero TotalAmount; the 5 zero-value rows are left in the count — a
   return event happened whether or not a peso value was captured for it,
   and the check's job is to surface the event, not silently drop it).
   HasGLCreditMemo (Detail only) = 1 when TicketRefNoVAT/TicketRefNoVATEX
   resolves to a POSTED CM-CLIENT-% ticket, 0 otherwise — CONFIRMED LIVE:
   26 of 96 returns resolve (= exactly check 4's population), 70 do NOT. This
   70-row / (₱3,405,042.08 - ₱1,476,101.10 = ₱1,928,940.98) gap is a genuine,
   material finding worth flagging to the developer as a FOLLOW-UP, not
   silently fixed or built into a new check here (out of THIS check's literal
   scope, which the brief defined as "count + value"): a large majority of
   recorded returns in this data have no corresponding GL credit memo posting
   at all, which could mean (a) those returns are pure physical/inventory
   events not yet financially settled with the customer, (b) they were
   settled through some other mechanism this pass didn't trace, or (c) a
   genuine revenue/AR-overstatement gap where goods came back but the
   customer's invoice was never reversed. Recommend a dedicated future check
   ("returns without a GL credit memo, aged") once the developer confirms
   which of these it is.
   SEVERITY: Warning — same reasoning as check 4; a return is a normal
   business event, this check exists for volume/pattern monitoring.

   ----------------------------------------------------------------------------
   CHECK 6 — SALES-CREDIT-LIMIT-BREACH — BUILT WITH EXPLICIT, HEAVILY
   DISCLOSED APPROXIMATIONS (per the brief's own instruction for this one)
   ----------------------------------------------------------------------------
   Investigated for a historical/point-in-time credit-limit snapshot — NONE
   EXISTS (re-confirmed the Agent Scorecard investigation's own finding: this
   ERP has essentially no master-data change history). Customers.
   CustomerCreditLimit is a live, current-value-only field. Per the brief's
   explicit permission, this check uses the CURRENT credit limit as an
   ACCEPTED APPROXIMATION for "the limit at order time" — documented here
   with the same rigor as sql/14's "current agent, all-time" decision: if a
   customer's credit limit has since changed, this check silently compares
   against the WRONG (current, not historical) limit for old orders. No way
   to detect or correct this with current data; flagged, not hidden.

   ORDER-TABLE INVESTIGATION (required before this check could be attempted
   at all): DeliverySummary is the only candidate order table (see check 2).
   CRITICAL FINDING: DeliverySummary carries NO CustomerKey column anywhere,
   and the only way to attribute a DeliverySummary row to a customer is via
   the SAME PONumber = TransactionChargeSales.ReferenceNo bridge used
   elsewhere in this file — CONFIRMED LIVE that bridge returns ZERO matches
   for Status IN ('PENDING','FOR DELIVERY') (0 of 45, 0 of 24) because
   invoicing (and therefore TransactionChargeSales row creation) does not
   happen until an order reaches DELIVERED. This means: for an order that is
   STILL OPEN — precisely the population where a credit check would have the
   most value, catching an over-limit order BEFORE goods ship — this schema
   captures NO CUSTOMER IDENTIFIER AT ALL. This check is therefore built
   ONLY against DELIVERED and RETURNED orders (2,041 of 2,090 non-open
   orders, customer fully resolvable — 0 unmatched confirmed live), evaluated
   RETROACTIVELY (would this order, at the balance it saw when placed, have
   breached the customer's CURRENT limit) rather than prospectively. PENDING/
   FOR DELIVERY orders (69 today) are EXCLUDED, not silently zero-filled —
   flagged here as a genuine, material schema gap for the developer: a
   forward-looking credit check is not currently possible with this ERP's
   data model, only a backward-looking one.

   POINT-IN-TIME BALANCE RECONSTRUCTION — ORIGINAL DESIGN (SUPERSEDED, kept
   here for history — see BUGFIX ADDENDUM below for what actually ships):
   the original design computed PriorBalance = the customer's EndingBalance
   from their most recent ClientLedger row strictly BEFORE the order's
   DeliverySummary.DateAdded, then BalanceAfterOrder = PriorBalance + this
   order's own TransactionChargeSales.TotalAmount. THIS WAS WRONG. Caught by
   accounting-reviewer on 2026-09-23: TransactionChargeSales.TransactionDate
   (and therefore the ClientLedger row this order's own invoice posts as) is
   confirmed live to fall BEFORE DeliverySummary.DateAdded in 2,029 of 2,041
   evaluable orders (99.4%) — i.e. "PriorBalance as of before ds.DateAdded"
   already CONTAINS this exact order's own invoice amount in the overwhelming
   majority of cases, and the +TotalAmount then added it a second time. Proof
   example: DeliveryNo 5309, CustomerKey 00001330, sole invoice ₱6,000 on
   2026-08-01 — true post-invoice ClientLedger.EndingBalance is ₱6,000; the
   old query computed PriorBalance=6000 (already the invoice) then
   BalanceAfterOrder=6000+6000=12000, exactly double. Same defect reproduced
   on DeliveryNo 5308/5310/5311/5312, and on this section's own hand-verified
   example below (DeliveryNo 5716) — there it was merely obscured by a second
   overlapping invoice sitting in the "prior" window, not a case that happened
   to be correct.

   BUGFIX ADDENDUM (2026-09-23, same day, before this check ever left DEV):
   PostOrderBalance is now looked up DIRECTLY from the order's OWN matching
   dbo.ClientLedger row(s) — TOP (1) EndingBalance WHERE AccountKey =
   CustomerKey AND InvoiceNo = (this order's own TransactionChargeSales.
   InvoiceNo) AND TransCode IN ('SI-VAT','SI-VATEX'), ORDER BY TRN_SEQ_NO
   DESC. This is the ledger's own true running balance immediately after THIS
   order's invoice posted — no re-addition of TotalAmount, because
   ClientLedger already did that arithmetic once, correctly, when the invoice
   was posted. TRN_SEQ_NO DESC matters: confirmed live that a single invoice
   can post as TWO ClientLedger legs under the same InvoiceNo (SI-VAT +
   SI-VATEX, one per VAT-ability split within the same invoice, e.g.
   CustomerKey 00009205 / InvoiceNo 'A-012286': TRN_SEQ_NO 1 = SI-VAT leg
   EndingBalance 1,200.00, TRN_SEQ_NO 2 = SI-VATEX leg EndingBalance
   15,941.90) — taking the LAST (highest TRN_SEQ_NO) of the two, not the
   first, is what gives the balance after the FULL invoice, not just its
   first leg. Re-verified DeliveryNo 5716 under the fix: PostOrderBalance
   comes back as exactly 792,092.00 — this order's own TotalAmount, meaning
   this customer's true balance right after this specific invoice was just
   this order's own amount, not 1,431,092 + 792,092 as the old query claimed.
   Re-verified DeliveryNo 5309: PostOrderBalance = 6,000.00, matching the
   proof example above exactly. 3 of 2,041 evaluable orders have no matching
   SI-VAT/SI-VATEX ClientLedger row at all (PostOrderBalance NULL) — these
   are EXCLUDED from the breach test (NULL > CreditLimit is unknown, not a
   breach), same "don't silently default into a false positive/negative"
   discipline as the CustomerKey-doesn't-resolve guard below; not a case
   worth a fallback since it affects 0.15% of the population and there is no
   safe substitute value to reconstruct.
   The Detail branch for this check uses the IDENTICAL PostOrderBalance
   subquery — Summary and Detail were sharing the same buggy logic before
   this fix and now share the identical corrected logic, so the summary card
   and its own drilldown cannot disagree.

   DATA-QUALITY FINDING, MATERIALITY-RELEVANT: CustomerCreditLimit is
   50,000.00 for 10,508 of 10,512 customers (99.96%) — confirmed live this is
   a system default, not an actively-managed per-customer figure (only 4
   customers have a distinct value: two at 2,000,000, one at 1,000,000, one
   at 3,000,000). This is a wholesale B2B meat trader where routine repeat
   customers carry six- and seven-figure running balances — a flat ₱50,000
   default will flag a large share of ordinary, healthy trade-credit
   customers, not just genuine risk. This is WHY severity is Warning, not
   Critical (see below), and is flagged prominently: this check becomes
   materially more useful the moment the developer starts setting real,
   differentiated per-customer limits.
   CONFIRMED LIVE UNDER THE FIX (2026-09-23, full history window): 464 of
   2,041 evaluable orders (23%) / 194 distinct customers breach — down from
   the pre-fix (buggy) 860 orders / 294 customers, a 46% drop in Findings, as
   expected once the double-count is removed. ValueAtRisk = ₱24,378,158.20
   (SUM of the breaching orders' own TotalAmount, same "flagged unit's own
   amount" convention as VOU-DUP-CHECKNO/VOU-DUP-SUPPLIER-INVOICE in sql/16 —
   NOT PostOrderBalance itself, which would still double-count a repeat
   customer's balance across each of their own flagged orders) — down from
   the pre-fix ₱32,444,001.87, a 25%/₱8.07M drop.
   SEVERITY CONCENTRATION RE-CHECKED POST-FIX: ALL 464 of 464 breaching
   orders (100%, up from 856/860 = 99.5% pre-fix) belong to the default-
   ₱50,000-limit population, not a customized-limit customer — the fix makes
   the "this is a default-limit signal, not a lending-risk signal" picture
   even more clear-cut than before, so Warning (not Critical) remains the
   correct severity, if anything more clearly justified than pre-fix.
   Orders whose CustomerKey does not resolve to a Customers row are EXCLUDED
   (never silently treated as a ₱0-limit customer, which would guarantee a
   false breach) — confirmed live this affects 0 of 2,041 orders today, but
   the guard is defensive, not currently load-bearing.
   SEVERITY: Warning (not Critical) — explicitly because CustomerCreditLimit
   is confirmed to be an unmanaged system default for 99.96% of customers
   today; a "breach" here is currently more a signal that the credit-limit
   field isn't yet an actively-used control than proof of a lending-risk
   failure. Revisit severity once real per-customer limits are set.

   ----------------------------------------------------------------------------
   CHECK 7 — SALES-BELOW-COST (manual price overrides below cost, or below a
   stored floor price) — PARTIALLY BUILT, PARTIALLY NOT, PER BRIEF'S OWN
   INSTRUCTION
   ----------------------------------------------------------------------------
   Cost-at-time-of-sale: CONFIRMED CAPTURED. TransactionChargeSalesDetails
   has both Cost and SellingPrice per line, populated for every SALES-type
   row (Cost populated 3,378/3,378 VATEX + 97/97 VAT; SellingPrice populated
   3,378/3,378 VATEX + 97/97 VAT) — this is real, per-transaction, at-the-
   time-of-sale data, not a current/live cost re-applied retroactively.
   Floor price: SEARCHED and NOT FOUND. INFORMATION_SCHEMA search for any
   column named like Floor/Minimum/MinPrice across the entire database
   returned zero results. dbo.Products carries Price1-Price4 (confirmed to be
   TIERED customer-class prices — isPrice1..isPrice4 flags on the same table
   suggest a customer is assigned to exactly one tier — not a floor/minimum
   guard price). CONCLUSION per the brief's explicit instruction: the
   floor-price HALF of this check is NOT BUILT (no data exists to build it
   against). The below-cost HALF, per the same instruction, IS BUILT since
   the data for it demonstrably exists.
   NAMING CAVEAT: no "manual override" flag or mechanism was found anywhere
   in the schema (no isOverride/isManualPrice-style column on
   TransactionChargeSalesDetails or DeliveryDetails) — this check therefore
   cannot distinguish a deliberately manually-overridden price from an
   ordinary system-quoted price that simply happens to be below cost. Named
   SALES-BELOW-COST (not "manual price override") to avoid implying a
   mechanism this data cannot prove; the underlying business risk (margin
   erosion) is identical either way and is what this check actually surfaces.
   CONFIRMED LIVE (2026-09-23): 577 SALES-type lines, 25 distinct products,
   13 of 13 branches, 2026-08-01 to 2026-09-14 — an ongoing, spread pattern,
   not a single fluke transaction. ValueAtRisk = SUM((Cost-SellingPrice) *
   Quantity) = ₱727,486.86 total margin erosion. Top single product (14017)
   alone accounts for ₱125,938.40.
   SEVERITY: Critical. Unlike the reversal/credit-memo checks above, there is
   no audited control action or legitimate business reason on file for
   selling below recorded cost — it is a direct, quantifiable, ongoing value
   leak across many products and branches, closer in nature to VOU-DUP-
   CHECKNO's "no explaining control action" reasoning than to the Warning-
   tier checks in this file.

   ----------------------------------------------------------------------------
   DB change protocol: the two shared procs already exist in DEV (built in
   sql/15, revised/extended in sql/16 [_OLD_20260923B/C] and sql/17
   [_OLD_20260923D]). Per CLAUDE.md / db-change-protocol, the current
   definitions are preserved under _OLD_20260923E rather than dropped, so all
   prior versions remain queryable.

   SAME-DAY BUGFIX PASS (2026-09-23, later the same day): accounting-reviewer
   caught the SALES-CREDIT-LIMIT-BREACH PriorBalance double-count documented
   above. Per protocol this is treated as another alteration, not a silent
   edit — checked what was actually live before picking a suffix (sql/18's
   own initial apply had already occupied _OLD_20260923E; a concurrent
   Purchasing-module pass could plausibly have taken F in the meantime, so
   live sys.objects was re-checked immediately before this pass, confirmed F
   still free) — the pre-bugfix definitions of both procs are preserved under
   _OLD_20260923F rather than dropped.
============================================================================ */


/* ============================================================================
   1. dbo.ExceptionDefinition — seed the 6 new SALES checks from this pass
   (SALES-DOC-SEQ-GAPS deliberately NOT seeded — not buildable, see header).
   No DDL change to the table itself.
============================================================================ */
MERGE dbo.ExceptionDefinition AS tgt
USING (VALUES
    ('SALES-UNCONFIRMED-ORDERS', 'Sales', 'Unconfirmed sales orders aged beyond threshold',
     'Warning',  1, '/ExceptionCenter/Detail?code=SALES-UNCONFIRMED-ORDERS', 50),
    ('SALES-VATABLE-ZERO-VAT',   'Sales', 'Vatable items posted with zero VAT calculated',
     'Critical', 1, '/ExceptionCenter/Detail?code=SALES-VATABLE-ZERO-VAT', 51),
    ('SALES-CM-CLIENT',          'Sales', 'Customer credit memos, by customer and agent',
     'Warning',  1, '/ExceptionCenter/Detail?code=SALES-CM-CLIENT', 52),
    ('SALES-RETURNED-ORDERS',    'Sales', 'Returned orders',
     'Warning',  1, '/ExceptionCenter/Detail?code=SALES-RETURNED-ORDERS', 53),
    ('SALES-CREDIT-LIMIT-BREACH','Sales', 'Orders that exceeded the customer credit limit',
     'Warning',  1, '/ExceptionCenter/Detail?code=SALES-CREDIT-LIMIT-BREACH', 54),
    ('SALES-BELOW-COST',         'Sales', 'Sales below recorded cost',
     'Critical', 1, '/ExceptionCenter/Detail?code=SALES-BELOW-COST', 55)
) AS src (ExceptionCode, Category, Title, Severity, HasDrillDown, DrillDownRoute, SortOrder)
ON tgt.ExceptionCode = src.ExceptionCode
WHEN MATCHED THEN
    UPDATE SET Category = src.Category, Title = src.Title, Severity = src.Severity,
               HasDrillDown = src.HasDrillDown, DrillDownRoute = src.DrillDownRoute,
               SortOrder = src.SortOrder, IsActive = 1
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ExceptionCode, Category, Title, Severity, HasDrillDown, DrillDownRoute, SortOrder)
    VALUES (src.ExceptionCode, src.Category, src.Title, src.Severity, src.HasDrillDown, src.DrillDownRoute, src.SortOrder);
GO


/* ============================================================================
   2. dbo.sp_rpt_ExceptionCenter_Summary — add 6 new INSERT blocks
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923F', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923F;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260923F';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL /* aging reference date for VOU-STALE-OUTSTANDING-
        CHECKS, AR-STALE-CREDIT-BALANCE, AND (new, this pass)
        SALES-UNCONFIRMED-ORDERS; defaults to @DateTo for the DAY-granularity
        checks (unchanged), but SALES-UNCONFIRMED-ORDERS below uses the true
        GETDATE() wall-clock (@AsOf) instead when @AsOfDate is NULL, since it
        needs HOUR granularity — see that check's own comment. */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE(); /* report-GENERATED-at timestamp,
        returned as-is in every row's AsOf output column — wall-clock "when
        was this report run", unrelated to the stale-aging dates below. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
        /* the as-of date VOU-STALE-OUTSTANDING-CHECKS and AR-STALE-CREDIT-
           BALANCE age against — DAY granularity, unchanged from sql/17. */
    DECLARE @StaleDays int = 30; /* PLACEHOLDER — bank-check clearing domain, see sql/16. */
    DECLARE @CreditBalanceStaleDays int = 90; /* PLACEHOLDER — AR credit-balance domain, see sql/17. */
    DECLARE @UnconfirmedOrderHours int = 24; /* PLACEHOLDER pending developer's
        real SLA — see header "CHECK 2". HOUR granularity, deliberately a
        separate concept from the two DAY-granularity thresholds above. */
    DECLARE @UnconfirmedAsOf datetime = ISNULL(CAST(@AsOfDate AS datetime), @AsOf);
        /* HOUR-granularity as-of reference for SALES-UNCONFIRMED-ORDERS only
           — reuses the real wall-clock @AsOf (not the date-only @StaleAsOf)
           when the caller doesn't pin @AsOfDate, so a same-day order's age
           is measured in real hours, not silently rounded to midnight. */

    CREATE TABLE #Result
    (
        ExceptionCode varchar(50) NOT NULL,
        Findings      int         NOT NULL,
        ValueAtRisk   money       NULL
    );

    /* ---- SOD-SAME-PREP-APPR: unchanged from sql/15-exception-center.sql ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SOD-SAME-PREP-APPR',
        COUNT(*),
        SUM(ISNULL(x.TicketValue, 0))
    FROM (
        SELECT
            tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
            TicketValue = COALESCE(strict.StrictSum, fallback.FallbackSum)
        FROM dbo.TicketMaster AS tm
        OUTER APPLY (
            SELECT StrictSum = SUM(td.Debit)
            FROM dbo.TicketDetails AS td
            WHERE td.TicketDate          = tm.TicketDate
              AND td.SupplementaryNumber = tm.SupplementaryNumber
              AND td.BranchCode          = tm.BranchCode
              AND td.TicketNumber        = tm.TicketNumber
        ) AS strict
        OUTER APPLY (
            SELECT FallbackSum = SUM(td.Debit)
            FROM dbo.TicketDetails AS td
            WHERE td.TicketDate          = tm.TicketDate
              AND td.SupplementaryNumber = tm.SupplementaryNumber
              AND td.TicketNumber        = tm.TicketNumber
        ) AS fallback
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND tm.TicketDate >= @Start AND tm.TicketDate < @End
          AND (
                   (NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.CheckedBy,'*'))
                OR (NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.ApprovedBy,'*'))
                OR (NULLIF(tm.CheckedBy,'*')  IS NOT NULL AND NULLIF(tm.CheckedBy,'*')  = NULLIF(tm.ApprovedBy,'*'))
              )
    ) AS x;

    /* ---- VOU-CANCELLED-CHECKS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-CANCELLED-CHECKS',
        COUNT(*),
        SUM(cv.Amount)
    FROM dbo.CheckVoucher AS cv
    WHERE cv.isErrorCorrect = 1
      AND cv.CancelledDate >= @Start AND cv.CancelledDate < @End;

    /* ---- VOU-REVERSED-VOUCHERS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-REVERSED-VOUCHERS',
        COUNT(*),
        SUM(COALESCE(cv.Amount, cash.Amount))
    FROM dbo.PaymentReversalAudit AS pra
    LEFT JOIN dbo.CheckVoucher AS cv
        ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cv.SupplierID = pra.SupplierID
    LEFT JOIN dbo.CashVoucher AS cash
        ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cash.SupplierID = pra.SupplierID
    WHERE pra.CancelledDate >= @Start AND pra.CancelledDate < @End;

    /* ---- VOU-DUP-CHECKNO: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-DUP-CHECKNO',
        COUNT(*),
        SUM(x.Amount)
    FROM (
        SELECT
            cv.VoucherID, cv.Amount,
            DupCount = COUNT(*) OVER (PARTITION BY cv.CreditGLCode, cv.CheckNo)
        FROM dbo.CheckVoucher AS cv
        WHERE cv.isErrorCorrect = 0
          AND cv.CreditGLCode IS NOT NULL AND LTRIM(RTRIM(cv.CreditGLCode)) <> ''
          AND cv.CheckNo      IS NOT NULL AND LTRIM(RTRIM(cv.CheckNo))      <> ''
          AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
    ) AS x
    WHERE x.DupCount > 1;

    /* ---- VOU-DUP-SUPPLIER-INVOICE: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-DUP-SUPPLIER-INVOICE',
        COUNT(*),
        SUM(y.PrincipalPaid)
    FROM (
        SELECT
            apd.SupplierID, apd.InvoiceNo,
            VoucherCount  = COUNT(DISTINCT apd.VoucherID),
            PrincipalPaid = SUM(CASE WHEN apd.PaymentType IN ('INVOICE PAYMENT','EXPENSE PAYMENT') THEN apd.Amount ELSE 0 END)
        FROM dbo.APPaymentDetails AS apd
        LEFT JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
           AND cv.SupplierID = apd.SupplierID
        LEFT JOIN dbo.CashVoucher AS cash
            ON cash.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
           AND cash.SupplierID = apd.SupplierID
        WHERE apd.InvoiceNo IS NOT NULL AND LTRIM(RTRIM(apd.InvoiceNo)) <> ''
          AND apd.InvoiceDate >= @Start AND apd.InvoiceDate < @End
          AND ISNULL(cv.isErrorCorrect, 0)   = 0
          AND ISNULL(cash.isErrorCorrect, 0) = 0
        GROUP BY apd.SupplierID, apd.InvoiceNo
        HAVING COUNT(DISTINCT apd.VoucherID) > 1
    ) AS y;

    /* ---- VOU-STALE-OUTSTANDING-CHECKS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-STALE-OUTSTANDING-CHECKS',
        COUNT(*),
        SUM(cv.Amount)
    FROM dbo.BankStatementRecon AS bsr
    JOIN dbo.CheckVoucher AS cv
        ON cv.VoucherID       = TRY_CAST(bsr.ReferenceNo AS decimal(18,0))
       AND cv.ReferenceNumber = bsr.SourceRef
    WHERE bsr.ItemType = 'OC' AND bsr.IsResolved = 0
      AND cv.isErrorCorrect = 0
      AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
      AND DATEDIFF(DAY, cv.CheckDate, @StaleAsOf) > @StaleDays;

    /* ---- EXP-REVERSALS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'EXP-REVERSALS',
        COUNT(*),
        SUM(COALESCE(cv.Amount, cash.Amount))
    FROM dbo.PaymentReversalAudit AS pra
    LEFT JOIN dbo.CheckVoucher AS cv
        ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cv.SupplierID = pra.SupplierID
    LEFT JOIN dbo.CashVoucher AS cash
        ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cash.SupplierID = pra.SupplierID
    WHERE pra.VoucherType = 'EXPENSE'
      AND pra.CancelledDate >= @Start AND pra.CancelledDate < @End;

    /* ---- AR-REVERSED-PAYMENTS: unchanged from sql/17 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'AR-REVERSED-PAYMENTS',
        COUNT(*),
        SUM(ph.TotalAmount)
    FROM dbo.PaymentHeader AS ph
    WHERE ph.Status = 'REVERSED'
      AND ph.ReversedDate >= @Start AND ph.ReversedDate < @End;

    /* ---- AR-STALE-CREDIT-BALANCE: unchanged from sql/17 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'AR-STALE-CREDIT-BALANCE',
        COUNT(*),
        SUM(ABS(t.Balance))
    FROM dbo.TransactionChargeSales AS t
    WHERE t.Balance < 0
      AND DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) > @CreditBalanceStaleDays;

    /* ---- SALES-UNCONFIRMED-ORDERS (NEW, this pass): DeliverySummary.Status
       = 'PENDING' orders, aged from the earliest real DeliveryDetails.
       DateTimeAdded on that DeliveryNo (falls back to midnight of
       DeliverySummary.DateAdded if a header has no detail rows — not
       observed live today, defensive only) to @UnconfirmedAsOf (HOUR
       granularity — see header). ValueAtRisk = SUM(DeliveryDetails.
       SellingPrice * QtyDelivered) per flagged header — CONFIRMED LIVE this
       is 0.00 today for every currently-open order (pricing isn't captured
       until later in this ERP's workflow, see header "CHECK 2" data-quality
       finding) — 0.00 is the honest current answer, not a bug. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-UNCONFIRMED-ORDERS',
        COUNT(*),
        SUM(ISNULL(v.OrderValue, 0))
    FROM (
        SELECT
            ds.DeliveryNo,
            PlacedAtTime = COALESCE(
                (SELECT MIN(dd.DateTimeAdded) FROM dbo.DeliveryDetails AS dd WHERE dd.DeliveryNo = ds.DeliveryNo),
                CAST(ds.DateAdded AS datetime))
        FROM dbo.DeliverySummary AS ds
        WHERE ds.Status = 'PENDING'
          AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
    ) AS p
    OUTER APPLY (
        SELECT OrderValue = SUM(dd.SellingPrice * dd.QtyDelivered)
        FROM dbo.DeliveryDetails AS dd
        WHERE dd.DeliveryNo = p.DeliveryNo
    ) AS v
    WHERE DATEDIFF(HOUR, p.PlacedAtTime, @UnconfirmedAsOf) > @UnconfirmedOrderHours;

    /* ---- SALES-VATABLE-ZERO-VAT (NEW, this pass): a vatable item
       (Products.isVat=1) posted as Type='SALES VAT EXEMPT' — see header
       "CHECK 3". ValueAtRisk = the actual posted SALES AMOUNT misclassified,
       not the derived VAT estimate (that estimate is DETAIL-only). ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-VATABLE-ZERO-VAT',
        COUNT(*),
        SUM(t.TotalAmount)
    FROM dbo.TransactionChargeSalesDetails AS t
    JOIN dbo.Products AS p ON p.ProductCode = t.Product
    WHERE t.Type = 'SALES VAT EXEMPT' AND p.isVat = 1
      AND t.TransactionDate >= @Start AND t.TransactionDate < @End;

    /* ---- SALES-CM-CLIENT (NEW, this pass): TicketMaster.Mnemonic
       classified via RptMnemonicMap (LIKE 'CM-CLIENT-%', not hardcoded),
       posted-only, bridged to TransactionChargeSales via ReferenceNumber =
       ReferenceNo (the sql/14-established bridge), value = the AR-control-
       account (vw_AccountTree.AncestorCode='101030101') Credit-Debit leg —
       see header "CHECK 4" for the full classification/severity rationale
       and the disclosed overlap with SALES-RETURNED-ORDERS. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-CM-CLIENT',
        COUNT(*),
        SUM(ISNULL(ar.ARValue, 0))
    FROM (
        SELECT tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber
        FROM dbo.TicketMaster AS tm
        JOIN dbo.RptMnemonicMap AS mm ON mm.Mnemonic = tm.Mnemonic
        WHERE mm.Mnemonic LIKE 'CM-CLIENT-%'
          AND tm.Status IN ('POSTED','UPDATED')
          AND tm.TicketDate >= @Start AND tm.TicketDate < @End
    ) AS c
    OUTER APPLY (
        SELECT ARValue = SUM(td.Credit - td.Debit)
        FROM dbo.TicketDetails AS td
        JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
        WHERE td.TicketDate          = c.TicketDate
          AND td.SupplementaryNumber = c.SupplementaryNumber
          AND td.BranchCode          = c.BranchCode
          AND td.TicketNumber        = c.TicketNumber
          AND t.AncestorCode = '101030101'
    ) AS ar;

    /* ---- SALES-RETURNED-ORDERS (NEW, this pass): straight read of
       ReturnedOrderSummary, windowed on DateAdded — see header "CHECK 5". ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-RETURNED-ORDERS',
        COUNT(*),
        SUM(ros.TotalAmount)
    FROM dbo.ReturnedOrderSummary AS ros
    WHERE ros.DateAdded >= @DateFrom AND ros.DateAdded < CAST(@End AS date);

    /* ---- SALES-CREDIT-LIMIT-BREACH (BUGFIXED 2026-09-23, same day as the
       original build — see header "CHECK 6" BUGFIX ADDENDUM): DELIVERED/
       RETURNED orders only (customer resolvable — see header for why
       PENDING/FOR DELIVERY cannot be evaluated). PostOrderBalance is looked
       up DIRECTLY from the order's OWN ClientLedger SI-VAT/SI-VATEX leg(s)
       (by CustomerKey+InvoiceNo, last TRN_SEQ_NO if an invoice split across
       both legs) — this IS the ledger's own true balance immediately after
       THIS order's invoice posted, so it is compared as-is against the
       CUSTOMER'S CURRENT credit limit (explicit approximation, disclosed),
       with NO re-addition of TotalAmount (the old query added TotalAmount a
       second time on top of a PriorBalance that, in 99.4% of orders, already
       contained this exact invoice — a straight double-count; see header for
       the full proof). Orders with no resolvable Customers row, or no
       matching ClientLedger SI leg at all (3 of 2,041 today), are excluded,
       never defaulted into a false breach/non-breach. ValueAtRisk = SUM of
       the breaching orders' own TotalAmount (not PostOrderBalance itself,
       which would still double-count a repeat customer's balance across
       each of their own flagged orders — same convention as VOU-DUP-CHECKNO/
       VOU-DUP-SUPPLIER-INVOICE in sql/16). ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-CREDIT-LIMIT-BREACH',
        COUNT(*),
        SUM(b.TotalAmount)
    FROM (
        SELECT
            ds.DeliveryNo, tcs.CustomerKey, tcs.TotalAmount,
            PostOrderBalance = (
                SELECT TOP (1) cl.EndingBalance
                FROM dbo.ClientLedger AS cl
                WHERE cl.AccountKey = tcs.CustomerKey
                  AND cl.InvoiceNo  = tcs.InvoiceNo
                  AND cl.TransCode IN ('SI-VAT','SI-VATEX')
                ORDER BY cl.TRN_SEQ_NO DESC
            )
        FROM dbo.DeliverySummary AS ds
        JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = ds.PONumber
        WHERE ds.Status IN ('DELIVERED','RETURNED')
          AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
    ) AS b
    JOIN dbo.Customers AS c ON c.CustomerKey = b.CustomerKey
    WHERE b.PostOrderBalance > ISNULL(c.CustomerCreditLimit, 0);

    /* ---- SALES-BELOW-COST (NEW, this pass): SALES-type lines where
       SellingPrice is populated (>0) and below the line's own recorded Cost
       — see header "CHECK 7" for why "manual override" and "floor price"
       are not provable/available, and why this is named/scoped as it is. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-BELOW-COST',
        COUNT(*),
        SUM((t.Cost - t.SellingPrice) * t.Quantity)
    FROM dbo.TransactionChargeSalesDetails AS t
    WHERE t.Type IN ('SALES VAT','SALES VAT EXEMPT')
      AND t.SellingPrice > 0 AND t.SellingPrice < t.Cost
      AND t.TransactionDate >= @Start AND t.TransactionDate < @End;

    /* ---- Future checks land here as additional INSERT blocks. ---- */

    SELECT
        ExceptionCode  = CAST(ed.ExceptionCode AS varchar(50)),
        Category       = CAST(ed.Category AS varchar(50)),
        Title          = CAST(ed.Title AS varchar(200)),
        Severity       = CAST(ed.Severity AS varchar(10)),
        Findings       = CAST(ISNULL(r.Findings, 0) AS int),
        ValueAtRisk    = CAST(r.ValueAtRisk AS decimal(18,2)),
        HasDrillDown   = CAST(ed.HasDrillDown AS bit),
        DrillDownRoute = CAST(ed.DrillDownRoute AS varchar(200)),
        AsOf           = CAST(@AsOf AS datetime)
    FROM dbo.ExceptionDefinition AS ed
    LEFT JOIN #Result AS r ON r.ExceptionCode = ed.ExceptionCode
    WHERE ed.IsActive = 1
    ORDER BY ed.SortOrder, ed.ExceptionCode;

    DROP TABLE #Result;
END
GO


/* ============================================================================
   3. dbo.sp_rpt_ExceptionCenter_Detail — add 6 new IF @ExceptionCode branches
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923F', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923F;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260923F';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail
    @ExceptionCode varchar(50),
    @DateFrom      date,
    @DateTo        date,
    @AsOfDate      date = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE();
    DECLARE @StaleDays int = 30; /* PLACEHOLDER — see Summary proc / sql/16 header note. */
    DECLARE @CreditBalanceStaleDays int = 90; /* PLACEHOLDER — see Summary proc / sql/17 header note. */
    DECLARE @UnconfirmedOrderHours int = 24; /* PLACEHOLDER — see Summary proc / this file's header note. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
    DECLARE @UnconfirmedAsOf datetime = ISNULL(CAST(@AsOfDate AS datetime), @AsOf);

    /* ==== SOD-SAME-PREP-APPR — unchanged from sql/15-exception-center.sql ==== */
    IF @ExceptionCode = 'SOD-SAME-PREP-APPR'
    BEGIN
        ;WITH Flagged AS
        (
            SELECT
                tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
                tm.ReferenceNumber, tm.Mnemonic, tm.Status, tm.Owner, tm.Particulars,
                tm.EnteredBy, tm.CheckedBy, tm.ApprovedBy,
                EnteredEqChecked  = CASE WHEN NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.CheckedBy,'*')  THEN 1 ELSE 0 END,
                EnteredEqApproved = CASE WHEN NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.ApprovedBy,'*') THEN 1 ELSE 0 END,
                CheckedEqApproved = CASE WHEN NULLIF(tm.CheckedBy,'*')  IS NOT NULL AND NULLIF(tm.CheckedBy,'*')  = NULLIF(tm.ApprovedBy,'*') THEN 1 ELSE 0 END
            FROM dbo.TicketMaster AS tm
            WHERE tm.Status IN ('POSTED','UPDATED')
              AND tm.TicketDate >= @Start AND tm.TicketDate < @End
        )
        SELECT TOP (500)
            TicketDate          = CAST(f.TicketDate AS date),
            BranchCode          = CAST(f.BranchCode AS varchar(5)),
            BranchName          = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            TicketNumber        = CAST(f.TicketNumber AS varchar(50)),
            SupplementaryNumber = CAST(f.SupplementaryNumber AS tinyint),
            ReferenceNumber     = CAST(ISNULL(f.ReferenceNumber, '') AS varchar(150)),
            Mnemonic            = CAST(ISNULL(f.Mnemonic, '') AS varchar(50)),
            Status              = CAST(ISNULL(f.Status, '') AS varchar(50)),
            EnteredBy           = CAST(ISNULL(f.EnteredBy, '') AS varchar(128)),
            CheckedBy           = CAST(ISNULL(f.CheckedBy, '') AS varchar(128)),
            ApprovedBy          = CAST(ISNULL(f.ApprovedBy, '') AS varchar(128)),
            MatchType           = CAST(
                                       STUFF(
                                           CASE WHEN f.EnteredEqChecked  = 1 THEN ', ENTERED=CHECKED'  ELSE '' END +
                                           CASE WHEN f.EnteredEqApproved = 1 THEN ', ENTERED=APPROVED' ELSE '' END +
                                           CASE WHEN f.CheckedEqApproved = 1 THEN ', CHECKED=APPROVED' ELSE '' END,
                                           1, 2, '')
                                   AS varchar(60)),
            InvolvesApprover    = CAST(CASE WHEN f.EnteredEqApproved = 1 OR f.CheckedEqApproved = 1 THEN 1 ELSE 0 END AS bit),
            TicketValue         = CAST(COALESCE(v.StrictSum, v.FallbackSum) AS decimal(18,2)),
            BranchCodeMismatch  = CAST(CASE WHEN v.StrictSum IS NULL AND v.FallbackSum IS NOT NULL THEN 1 ELSE 0 END AS bit),
            Owner               = CAST(ISNULL(f.Owner, '') AS varchar(150)),
            Particulars         = CAST(ISNULL(f.Particulars, '') AS varchar(400))
        FROM Flagged AS f
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = f.BranchCode
        OUTER APPLY (
            SELECT
                StrictSum = (
                    SELECT SUM(td.Debit)
                    FROM dbo.TicketDetails AS td
                    WHERE td.TicketDate          = f.TicketDate
                      AND td.SupplementaryNumber = f.SupplementaryNumber
                      AND td.BranchCode          = f.BranchCode
                      AND td.TicketNumber        = f.TicketNumber
                ),
                FallbackSum = (
                    SELECT SUM(td.Debit)
                    FROM dbo.TicketDetails AS td
                    WHERE td.TicketDate          = f.TicketDate
                      AND td.SupplementaryNumber = f.SupplementaryNumber
                      AND td.TicketNumber        = f.TicketNumber
                )
        ) AS v
        WHERE f.EnteredEqChecked = 1 OR f.EnteredEqApproved = 1 OR f.CheckedEqApproved = 1
        ORDER BY f.EnteredEqApproved DESC, f.CheckedEqApproved DESC, f.TicketDate DESC;
        RETURN;
    END

    /* ==== VOU-CANCELLED-CHECKS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-CANCELLED-CHECKS'
    BEGIN
        SELECT TOP (500)
            VoucherID     = CAST(cv.VoucherID AS varchar(20)),
            SupplierID    = CAST(cv.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(cv.ReferenceNumber, '') AS varchar(20)),
            CheckNo       = CAST(ISNULL(cv.CheckNo, '') AS varchar(100)),
            CheckDate     = CAST(cv.CheckDate AS date),
            Amount        = CAST(cv.Amount AS decimal(18,2)),
            BankAccountCode = CAST(ISNULL(cv.CreditGLCode, '') AS varchar(100)),
            BankName      = CAST(ISNULL(bc.Bank, '') AS varchar(50)),
            BranchCode    = CAST(ISNULL(ap.BranchCode, '') AS varchar(5)),
            Particulars   = CAST(ISNULL(cv.Particulars, '') AS varchar(500)),
            CancelledBy   = CAST(ISNULL(cv.CancelledBy, '') AS varchar(50)),
            CancelledDate = CAST(cv.CancelledDate AS datetime),
            CancelReason  = CAST(ISNULL(cv.CancelReason, '') AS varchar(300))
        FROM dbo.CheckVoucher AS cv
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = cv.SupplierID
        LEFT JOIN dbo.BankCOA AS bc ON bc.AccountCode = cv.CreditGLCode
        OUTER APPLY (
            SELECT TOP (1) BranchCode
            FROM dbo.APPaymentDetails ap
            WHERE ap.VoucherID = CAST(cv.VoucherID AS varchar(10))
              AND ap.SupplierID = cv.SupplierID
              AND ap.ReferenceNumber = cv.ReferenceNumber
        ) AS ap
        WHERE cv.isErrorCorrect = 1
          AND cv.CancelledDate >= @Start AND cv.CancelledDate < @End
        ORDER BY cv.CancelledDate DESC;
        RETURN;
    END

    /* ==== VOU-REVERSED-VOUCHERS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-REVERSED-VOUCHERS'
    BEGIN
        SELECT TOP (500)
            AuditID       = CAST(pra.AuditID AS int),
            VoucherID     = CAST(pra.VoucherID AS varchar(20)),
            SourceTable   = CAST(CASE WHEN cv.VoucherID IS NOT NULL THEN 'CHECK'
                                      WHEN cash.VoucherID IS NOT NULL THEN 'CASH'
                                      ELSE 'UNKNOWN' END AS varchar(10)),
            SupplierID    = CAST(pra.SupplierID AS varchar(40)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            VoucherType   = CAST(ISNULL(pra.VoucherType, '') AS varchar(20)),
            ReferenceNumber = CAST(ISNULL(pra.ReferenceNumber, '') AS varchar(20)),
            Amount        = CAST(COALESCE(cv.Amount, cash.Amount) AS decimal(18,2)),
            CancelledBy   = CAST(ISNULL(pra.CancelledBy, '') AS varchar(50)),
            CancelledDate = CAST(pra.CancelledDate AS datetime),
            CancelReason  = CAST(ISNULL(pra.CancelReason, '') AS varchar(300))
        FROM dbo.PaymentReversalAudit AS pra
        LEFT JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cv.SupplierID = pra.SupplierID
        LEFT JOIN dbo.CashVoucher AS cash
            ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cash.SupplierID = pra.SupplierID
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = pra.SupplierID
        WHERE pra.CancelledDate >= @Start AND pra.CancelledDate < @End
        ORDER BY pra.CancelledDate DESC;
        RETURN;
    END

    /* ==== VOU-DUP-CHECKNO — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-DUP-CHECKNO'
    BEGIN
        ;WITH Flagged AS (
            SELECT
                cv.VoucherID, cv.SupplierID, cv.ReferenceNumber, cv.CheckNo, cv.CheckDate,
                cv.Amount, cv.CreditGLCode, cv.PreparedBy,
                DupCount = COUNT(*) OVER (PARTITION BY cv.CreditGLCode, cv.CheckNo)
            FROM dbo.CheckVoucher AS cv
            WHERE cv.isErrorCorrect = 0
              AND cv.CreditGLCode IS NOT NULL AND LTRIM(RTRIM(cv.CreditGLCode)) <> ''
              AND cv.CheckNo      IS NOT NULL AND LTRIM(RTRIM(cv.CheckNo))      <> ''
              AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
        )
        SELECT TOP (500)
            VoucherID     = CAST(f.VoucherID AS varchar(20)),
            SupplierID    = CAST(f.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(f.ReferenceNumber, '') AS varchar(20)),
            CheckNo       = CAST(f.CheckNo AS varchar(100)),
            CheckDate     = CAST(f.CheckDate AS date),
            Amount        = CAST(f.Amount AS decimal(18,2)),
            BankAccountCode = CAST(f.CreditGLCode AS varchar(100)),
            BankName      = CAST(ISNULL(bc.Bank, '') AS varchar(50)),
            DuplicateCount = CAST(f.DupCount AS int),
            PreparedBy    = CAST(ISNULL(f.PreparedBy, '') AS varchar(50))
        FROM Flagged AS f
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = f.SupplierID
        LEFT JOIN dbo.BankCOA AS bc ON bc.AccountCode = f.CreditGLCode
        WHERE f.DupCount > 1
        ORDER BY f.CreditGLCode, f.CheckNo, f.CheckDate;
        RETURN;
    END

    /* ==== VOU-DUP-SUPPLIER-INVOICE — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-DUP-SUPPLIER-INVOICE'
    BEGIN
        ;WITH LiveLegs AS (
            SELECT
                apd.SupplierID, apd.InvoiceNo, apd.VoucherID, apd.VoucherType,
                apd.PaymentMethod, apd.ReferenceNumber, apd.InvoiceDate,
                apd.PaymentType, apd.Amount
            FROM dbo.APPaymentDetails AS apd
            LEFT JOIN dbo.CheckVoucher AS cv
                ON cv.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
               AND cv.SupplierID = apd.SupplierID
            LEFT JOIN dbo.CashVoucher AS cash
                ON cash.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
               AND cash.SupplierID = apd.SupplierID
            WHERE apd.InvoiceNo IS NOT NULL AND LTRIM(RTRIM(apd.InvoiceNo)) <> ''
              AND apd.InvoiceDate >= @Start AND apd.InvoiceDate < @End
              AND ISNULL(cv.isErrorCorrect, 0)   = 0
              AND ISNULL(cash.isErrorCorrect, 0) = 0
        ),
        FlaggedPairs AS (
            SELECT SupplierID, InvoiceNo
            FROM LiveLegs
            GROUP BY SupplierID, InvoiceNo
            HAVING COUNT(DISTINCT VoucherID) > 1
        )
        SELECT TOP (500)
            SupplierID    = CAST(v.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            InvoiceNo     = CAST(v.InvoiceNo AS varchar(150)),
            InvoiceDate   = CAST(v.InvoiceDate AS date),
            VoucherID     = CAST(v.VoucherID AS varchar(20)),
            VoucherType   = CAST(ISNULL(v.VoucherType, '') AS varchar(20)),
            PaymentMethod = CAST(ISNULL(v.PaymentMethod, '') AS varchar(20)),
            ReferenceNumber = CAST(ISNULL(v.ReferenceNumber, '') AS varchar(20)),
            PrincipalPaid = CAST(v.PrincipalPaid AS decimal(18,2))
        FROM FlaggedPairs AS fp
        JOIN (
            SELECT
                SupplierID, InvoiceNo, VoucherID, VoucherType,
                PaymentMethod, ReferenceNumber, MIN(InvoiceDate) AS InvoiceDate,
                PrincipalPaid = SUM(CASE WHEN PaymentType IN ('INVOICE PAYMENT','EXPENSE PAYMENT') THEN Amount ELSE 0 END)
            FROM LiveLegs
            GROUP BY SupplierID, InvoiceNo, VoucherID, VoucherType, PaymentMethod, ReferenceNumber
        ) AS v
            ON v.SupplierID = fp.SupplierID AND v.InvoiceNo = fp.InvoiceNo
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = v.SupplierID
        ORDER BY v.SupplierID, v.InvoiceNo, v.VoucherID;
        RETURN;
    END

    /* ==== VOU-STALE-OUTSTANDING-CHECKS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-STALE-OUTSTANDING-CHECKS'
    BEGIN
        SELECT TOP (500)
            VoucherID     = CAST(cv.VoucherID AS varchar(20)),
            SupplierID    = CAST(cv.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(cv.ReferenceNumber, '') AS varchar(20)),
            CheckNo       = CAST(ISNULL(cv.CheckNo, '') AS varchar(100)),
            CheckDate     = CAST(cv.CheckDate AS date),
            Amount        = CAST(cv.Amount AS decimal(18,2)),
            BankAccountCode = CAST(ISNULL(bsr.AccountCode, '') AS varchar(20)),
            BankName      = CAST(ISNULL(bc.Bank, '') AS varchar(50)),
            BranchCode    = CAST(ISNULL(bsr.BranchCode, '') AS varchar(5)),
            DaysOutstanding = CAST(DATEDIFF(DAY, cv.CheckDate, @StaleAsOf) AS int),
            Payee         = CAST(ISNULL(bsr.Payee, '') AS varchar(200))
        FROM dbo.BankStatementRecon AS bsr
        JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID       = TRY_CAST(bsr.ReferenceNo AS decimal(18,0))
           AND cv.ReferenceNumber = bsr.SourceRef
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = cv.SupplierID
        LEFT JOIN dbo.BankCOA AS bc ON bc.AccountCode = bsr.AccountCode
        WHERE bsr.ItemType = 'OC' AND bsr.IsResolved = 0
          AND cv.isErrorCorrect = 0
          AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
          AND DATEDIFF(DAY, cv.CheckDate, @StaleAsOf) > @StaleDays
        ORDER BY DaysOutstanding DESC;
        RETURN;
    END

    /* ==== EXP-REVERSALS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'EXP-REVERSALS'
    BEGIN
        SELECT TOP (500)
            AuditID       = CAST(pra.AuditID AS int),
            VoucherID     = CAST(pra.VoucherID AS varchar(20)),
            SourceTable   = CAST(CASE WHEN cv.VoucherID IS NOT NULL THEN 'CHECK'
                                      WHEN cash.VoucherID IS NOT NULL THEN 'CASH'
                                      ELSE 'UNKNOWN' END AS varchar(10)),
            SupplierID    = CAST(pra.SupplierID AS varchar(40)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(pra.ReferenceNumber, '') AS varchar(20)),
            Amount        = CAST(COALESCE(cv.Amount, cash.Amount) AS decimal(18,2)),
            CancelledBy   = CAST(ISNULL(pra.CancelledBy, '') AS varchar(50)),
            CancelledDate = CAST(pra.CancelledDate AS datetime),
            CancelReason  = CAST(ISNULL(pra.CancelReason, '') AS varchar(300))
        FROM dbo.PaymentReversalAudit AS pra
        LEFT JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cv.SupplierID = pra.SupplierID
        LEFT JOIN dbo.CashVoucher AS cash
            ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cash.SupplierID = pra.SupplierID
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = pra.SupplierID
        WHERE pra.VoucherType = 'EXPENSE'
          AND pra.CancelledDate >= @Start AND pra.CancelledDate < @End
        ORDER BY pra.CancelledDate DESC;
        RETURN;
    END

    /* ==== AR-REVERSED-PAYMENTS — unchanged from sql/17 ==== */
    IF @ExceptionCode = 'AR-REVERSED-PAYMENTS'
    BEGIN
        SELECT TOP (500)
            PaymentHeaderID = CAST(ph.PaymentHeaderID AS varchar(20)),
            CustomerKey     = CAST(ph.CustomerKey AS char(8)),
            CustomerName    = CAST(ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + ph.CustomerKey) AS varchar(200)),
            BranchCode      = CAST(ISNULL(c.BranchCode, 'UNKNOWN') AS varchar(100)),
            ReferenceNo     = CAST(ISNULL(ph.ReferenceNo, '') AS varchar(20)),
            PaymentType     = CAST(ISNULL(ph.PaymentType, '') AS varchar(30)),
            PaymentDate     = CAST(ph.PaymentDate AS date),
            TotalAmount     = CAST(ph.TotalAmount AS decimal(18,2)),
            ReversedBy      = CAST(ISNULL(ph.ReversedBy, '') AS varchar(50)),
            ReversedDate    = CAST(ph.ReversedDate AS datetime),
            Remarks         = CAST(ISNULL(ph.Remarks, '') AS varchar(500))
        FROM dbo.PaymentHeader AS ph
        LEFT JOIN dbo.Customers AS c ON c.CustomerKey = ph.CustomerKey
        WHERE ph.Status = 'REVERSED'
          AND ph.ReversedDate >= @Start AND ph.ReversedDate < @End
        ORDER BY ph.ReversedDate DESC;
        RETURN;
    END

    /* ==== AR-STALE-CREDIT-BALANCE — unchanged from sql/17 ==== */
    IF @ExceptionCode = 'AR-STALE-CREDIT-BALANCE'
    BEGIN
        SELECT TOP (500)
            CustomerKey     = CAST(t.CustomerKey AS char(8)),
            CustomerName    = CAST(ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + t.CustomerKey) AS varchar(200)),
            BranchCode      = CAST(ISNULL(c.BranchCode, 'UNKNOWN') AS varchar(100)),
            InvoiceNo       = CAST(t.InvoiceNo AS varchar(100)),
            TransactionDate = CAST(t.TransactionDate AS date),
            TotalAmount     = CAST(t.TotalAmount AS decimal(18,2)),
            CreditBalance   = CAST(ABS(t.Balance) AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(t.PayStatus, '') AS varchar(10)),
            DaysOpen        = CAST(DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) AS int)
        FROM dbo.TransactionChargeSales AS t
        LEFT JOIN dbo.Customers AS c ON c.CustomerKey = t.CustomerKey
        WHERE t.Balance < 0
          AND DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) > @CreditBalanceStaleDays
        ORDER BY DaysOpen DESC;
        RETURN;
    END

    /* ==== SALES-UNCONFIRMED-ORDERS (NEW, this pass) — one row per flagged
       PENDING order, HoursOpen computed against @UnconfirmedAsOf. ==== */
    IF @ExceptionCode = 'SALES-UNCONFIRMED-ORDERS'
    BEGIN
        ;WITH PlacedAt AS (
            SELECT
                ds.DeliveryNo, ds.PONumber, ds.BranchCode, ds.Status, ds.DateAdded, ds.PreparedBy, ds.TotalItem,
                PlacedAtTime = COALESCE(
                    (SELECT MIN(dd.DateTimeAdded) FROM dbo.DeliveryDetails AS dd WHERE dd.DeliveryNo = ds.DeliveryNo),
                    CAST(ds.DateAdded AS datetime))
            FROM dbo.DeliverySummary AS ds
            WHERE ds.Status = 'PENDING'
              AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
        )
        SELECT TOP (500)
            DeliveryNo   = CAST(p.DeliveryNo AS varchar(20)),
            PONumber     = CAST(p.PONumber AS varchar(20)),
            BranchCode   = CAST(p.BranchCode AS varchar(5)),
            BranchName   = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            DateAdded    = CAST(p.DateAdded AS date),
            PlacedAtTime = CAST(p.PlacedAtTime AS datetime),
            HoursOpen    = CAST(DATEDIFF(HOUR, p.PlacedAtTime, @UnconfirmedAsOf) AS int),
            OrderValue   = CAST(ISNULL(v.OrderValue, 0) AS decimal(18,2)),
            TotalItem    = CAST(ISNULL(p.TotalItem, 0) AS int),
            PreparedBy   = CAST(ISNULL(p.PreparedBy, '') AS varchar(30))
        FROM PlacedAt AS p
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = p.BranchCode
        OUTER APPLY (
            SELECT OrderValue = SUM(dd.SellingPrice * dd.QtyDelivered)
            FROM dbo.DeliveryDetails AS dd
            WHERE dd.DeliveryNo = p.DeliveryNo
        ) AS v
        WHERE DATEDIFF(HOUR, p.PlacedAtTime, @UnconfirmedAsOf) > @UnconfirmedOrderHours
        ORDER BY HoursOpen DESC;
        RETURN;
    END

    /* ==== SALES-VATABLE-ZERO-VAT (NEW, this pass) — one row per flagged
       line; EstimatedVATShortfall is a DERIVED estimate (12% VAT backed out
       of the VAT-inclusive selling price), labeled as such, not a posted GL
       figure — see header "CHECK 3". ==== */
    IF @ExceptionCode = 'SALES-VATABLE-ZERO-VAT'
    BEGIN
        SELECT TOP (500)
            BranchCode      = CAST(t.BranchCode AS varchar(5)),
            ReferenceNo     = CAST(t.ReferenceNo AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            TransactionDate = CAST(t.TransactionDate AS date),
            ProductCode     = CAST(t.Product AS varchar(50)),
            ProductDescription = CAST(ISNULL(p.Description, '') AS varchar(100)),
            Quantity        = CAST(t.Quantity AS decimal(18,3)),
            SellingPrice    = CAST(t.SellingPrice AS decimal(18,2)),
            TotalAmount     = CAST(t.TotalAmount AS decimal(18,2)),
            EstimatedVATShortfall = CAST(ROUND(t.TotalAmount / 1.12 * 0.12, 2) AS decimal(18,2))
        FROM dbo.TransactionChargeSalesDetails AS t
        JOIN dbo.Products AS p ON p.ProductCode = t.Product
        WHERE t.Type = 'SALES VAT EXEMPT' AND p.isVat = 1
          AND t.TransactionDate >= @Start AND t.TransactionDate < @End
        ORDER BY t.TransactionDate DESC;
        RETURN;
    END

    /* ==== SALES-CM-CLIENT (NEW, this pass) — one row per flagged credit
       memo ticket, with CustomerName + AgentLabel (current-agent, all-time —
       same disclosed limitation as sql/14's Agent Scorecard). ==== */
    IF @ExceptionCode = 'SALES-CM-CLIENT'
    BEGIN
        ;WITH CMTickets AS (
            SELECT tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
                   tm.ReferenceNumber, tm.Mnemonic, tm.Particulars
            FROM dbo.TicketMaster AS tm
            JOIN dbo.RptMnemonicMap AS mm ON mm.Mnemonic = tm.Mnemonic
            WHERE mm.Mnemonic LIKE 'CM-CLIENT-%'
              AND tm.Status IN ('POSTED','UPDATED')
              AND tm.TicketDate >= @Start AND tm.TicketDate < @End
        )
        SELECT TOP (500)
            TicketDate      = CAST(c.TicketDate AS date),
            BranchCode      = CAST(c.BranchCode AS varchar(5)),
            TicketNumber    = CAST(c.TicketNumber AS varchar(50)),
            ReferenceNumber = CAST(ISNULL(c.ReferenceNumber, '') AS varchar(150)),
            Mnemonic        = CAST(ISNULL(c.Mnemonic, '') AS varchar(50)),
            CustomerKey     = CAST(ISNULL(tcs.CustomerKey, '') AS varchar(8)),
            CustomerName    = CAST(ISNULL(cust.CustomerName, '') AS varchar(200)),
            AgentLabel      = CAST(ISNULL(NULLIF(LTRIM(RTRIM(cust.AccountOfficer)), ''), 'UNASSIGNED') AS varchar(50)),
            ARValue         = CAST(ISNULL(ar.ARValue, 0) AS decimal(18,2)),
            Particulars     = CAST(ISNULL(c.Particulars, '') AS varchar(400))
        FROM CMTickets AS c
        LEFT JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = c.ReferenceNumber
        LEFT JOIN dbo.Customers AS cust ON cust.CustomerKey = tcs.CustomerKey
        OUTER APPLY (
            SELECT ARValue = SUM(td.Credit - td.Debit)
            FROM dbo.TicketDetails AS td
            JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
            WHERE td.TicketDate          = c.TicketDate
              AND td.SupplementaryNumber = c.SupplementaryNumber
              AND td.BranchCode          = c.BranchCode
              AND td.TicketNumber        = c.TicketNumber
              AND t.AncestorCode = '101030101'
        ) AS ar
        ORDER BY c.TicketDate DESC;
        RETURN;
    END

    /* ==== SALES-RETURNED-ORDERS (NEW, this pass) — one row per return;
       HasGLCreditMemo discloses the overlap with SALES-CM-CLIENT documented
       in the header rather than leaving it implicit.
       DEFENSIVE NOTE (accounting-reviewer, 2026-09-23): this join matches
       tm.TicketNumber alone, with no tm.BranchCode qualifier, on the
       ASSUMPTION that TicketNumber is unique among CM-CLIENT-% postings —
       confirmed live today this holds (0 cross-branch TicketNumber
       collisions among CM-CLIENT-% tickets). TicketNumber is NOT globally
       unique in TicketMaster in general (it repeats per BranchCode across
       other mnemonics elsewhere in this portal, which is why every other
       ticket-level join in this codebase keys on the full
       TicketDate+SupplementaryNumber+BranchCode+TicketNumber tuple). If a
       future CM-CLIENT-% posting ever collides on TicketNumber across two
       branches, this join would silently attribute the wrong branch's
       credit memo to a return — re-check this assumption before trusting
       HasGLCreditMemo if that data-quality fact ever changes. ==== */
    IF @ExceptionCode = 'SALES-RETURNED-ORDERS'
    BEGIN
        SELECT TOP (500)
            PONumber        = CAST(ros.PONumber AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(ros.InvoiceNo, '') AS varchar(50)),
            BranchCode      = CAST(ros.BranchCode AS varchar(20)),
            DateAdded       = CAST(ros.DateAdded AS date),
            TotalAmount     = CAST(ISNULL(ros.TotalAmount, 0) AS decimal(18,2)),
            PreparedBy      = CAST(ISNULL(ros.PreparedBy, '') AS varchar(30)),
            Reason          = CAST(ISNULL(ros.Reason, '') AS varchar(3000)),
            HasGLCreditMemo = CAST(CASE WHEN tm.TicketNumber IS NOT NULL THEN 1 ELSE 0 END AS bit)
        FROM dbo.ReturnedOrderSummary AS ros
        LEFT JOIN dbo.TicketMaster AS tm
            ON tm.TicketNumber IN (ros.TicketRefNoVAT, ros.TicketRefNoVATEX)
           AND tm.Mnemonic LIKE 'CM-CLIENT-%'
           AND tm.Status IN ('POSTED','UPDATED')
           /* TicketNumber-only join — see DEFENSIVE NOTE above */
        WHERE ros.DateAdded >= @DateFrom AND ros.DateAdded < CAST(@End AS date)
        ORDER BY ros.DateAdded DESC;
        RETURN;
    END

    /* ==== SALES-CREDIT-LIMIT-BREACH (BUGFIXED 2026-09-23 — see header
       "CHECK 6" BUGFIX ADDENDUM and the matching Summary block above; this
       branch uses the IDENTICAL PostOrderBalance subquery as the Summary
       proc so the two can never disagree) — one row per breaching order;
       ExcessOverLimit surfaces the magnitude. BranchCode added (the selling
       branch, from TransactionChargeSales — same convention as every other
       Sales check in this file) for consistency; this check was the only
       one of the 6 missing it. ==== */
    IF @ExceptionCode = 'SALES-CREDIT-LIMIT-BREACH'
    BEGIN
        ;WITH Orders AS (
            SELECT
                ds.DeliveryNo, ds.PONumber, ds.Status, ds.DateAdded,
                tcs.CustomerKey, tcs.BranchCode, tcs.InvoiceNo, tcs.TotalAmount,
                PostOrderBalance = (
                    SELECT TOP (1) cl.EndingBalance
                    FROM dbo.ClientLedger AS cl
                    WHERE cl.AccountKey = tcs.CustomerKey
                      AND cl.InvoiceNo  = tcs.InvoiceNo
                      AND cl.TransCode IN ('SI-VAT','SI-VATEX')
                    ORDER BY cl.TRN_SEQ_NO DESC
                )
            FROM dbo.DeliverySummary AS ds
            JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = ds.PONumber
            WHERE ds.Status IN ('DELIVERED','RETURNED')
              AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
        )
        SELECT TOP (500)
            DeliveryNo        = CAST(o.DeliveryNo AS varchar(20)),
            PONumber          = CAST(o.PONumber AS varchar(20)),
            BranchCode        = CAST(o.BranchCode AS varchar(5)),
            BranchName        = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            Status            = CAST(o.Status AS varchar(50)),
            DateAdded         = CAST(o.DateAdded AS date),
            CustomerKey       = CAST(o.CustomerKey AS char(8)),
            CustomerName      = CAST(ISNULL(c.CustomerName, '') AS varchar(200)),
            OrderAmount       = CAST(o.TotalAmount AS decimal(18,2)),
            BalanceAfterOrder = CAST(o.PostOrderBalance AS decimal(18,2)),
            CreditLimit       = CAST(c.CustomerCreditLimit AS decimal(18,2)),
            ExcessOverLimit   = CAST(o.PostOrderBalance - c.CustomerCreditLimit AS decimal(18,2))
        FROM Orders AS o
        JOIN dbo.Customers AS c ON c.CustomerKey = o.CustomerKey
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = o.BranchCode
        WHERE o.PostOrderBalance > ISNULL(c.CustomerCreditLimit, 0)
        ORDER BY ExcessOverLimit DESC;
        RETURN;
    END

    /* ==== SALES-BELOW-COST (NEW, this pass) — one row per flagged line. ==== */
    IF @ExceptionCode = 'SALES-BELOW-COST'
    BEGIN
        SELECT TOP (500)
            BranchCode      = CAST(t.BranchCode AS varchar(5)),
            ReferenceNo     = CAST(t.ReferenceNo AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            TransactionDate = CAST(t.TransactionDate AS date),
            ProductCode     = CAST(t.Product AS varchar(50)),
            ProductDescription = CAST(ISNULL(p.Description, '') AS varchar(100)),
            Quantity        = CAST(t.Quantity AS decimal(18,3)),
            Cost            = CAST(t.Cost AS decimal(18,2)),
            SellingPrice    = CAST(t.SellingPrice AS decimal(18,2)),
            MarginLossPerUnit = CAST(t.Cost - t.SellingPrice AS decimal(18,2)),
            TotalMarginLoss = CAST((t.Cost - t.SellingPrice) * t.Quantity AS decimal(18,2))
        FROM dbo.TransactionChargeSalesDetails AS t
        LEFT JOIN dbo.Products AS p ON p.ProductCode = t.Product
        WHERE t.Type IN ('SALES VAT','SALES VAT EXEMPT')
          AND t.SellingPrice > 0 AND t.SellingPrice < t.Cost
          AND t.TransactionDate >= @Start AND t.TransactionDate < @End
        ORDER BY TotalMarginLoss DESC;
        RETURN;
    END

    /* ==== Unknown @ExceptionCode — fail loudly ==== */
    RAISERROR('sp_rpt_ExceptionCenter_Detail: unknown or not-yet-implemented @ExceptionCode ''%s''.', 16, 1, @ExceptionCode);
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
DECLARE @From date = '2020-01-01', @To date = '2026-12-31';

EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect (verified live against DEV on 2026-09-23), 9 prior checks UNCHANGED:
--   SOD-SAME-PREP-APPR              Findings=1   ValueAtRisk=3688581595.84
--   VOU-CANCELLED-CHECKS            Findings=3   ValueAtRisk=334550.59
--   VOU-REVERSED-VOUCHERS           Findings=4   ValueAtRisk=349550.59
--   VOU-DUP-CHECKNO                 Findings=7   ValueAtRisk=583184.37
--   VOU-DUP-SUPPLIER-INVOICE        Findings=2   ValueAtRisk=1062922.85
--   VOU-STALE-OUTSTANDING-CHECKS    Findings=1   ValueAtRisk=26153.50
--   EXP-REVERSALS                   Findings=4   ValueAtRisk=349550.59
--   AR-REVERSED-PAYMENTS            Findings=1   ValueAtRisk=9049.60
--   AR-STALE-CREDIT-BALANCE         Findings=169 ValueAtRisk=2039671.87
-- Plus 6 NEW this pass:
--   SALES-UNCONFIRMED-ORDERS        Findings=45  ValueAtRisk=0.00
--     (all 45 currently-PENDING orders are already >24h old; ValueAtRisk is
--      genuinely 0.00 today — SellingPrice isn't captured on open orders,
--      see header "CHECK 2")
--   SALES-VATABLE-ZERO-VAT          Findings=75  ValueAtRisk=114000.00
--     (5 invoices, 1 product — AVIKO SHOESTRING FRIES (1KG), ProductCode
--      12050 — BranchCode 888, all dated 2026-08-06)
--   SALES-CM-CLIENT                 Findings=26  ValueAtRisk=1476101.10
--   SALES-RETURNED-ORDERS           Findings=96  ValueAtRisk=3405042.08
--   SALES-CREDIT-LIMIT-BREACH       Findings=464 ValueAtRisk=24378158.20
--     (BUGFIXED 2026-09-23 — see header "CHECK 6" BUGFIX ADDENDUM; was
--      Findings=860 ValueAtRisk=32444001.87 pre-fix, a PriorBalance
--      double-count. Of 2,041 evaluable DELIVERED/RETURNED orders;
--      PENDING/FOR DELIVERY orders cannot be evaluated at all)
--   SALES-BELOW-COST                Findings=577 ValueAtRisk=727486.86

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'SALES-UNCONFIRMED-ORDERS', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect 45 rows, OrderValue = 0.00 on every row (see above), HoursOpen sorted descending.

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'SALES-VATABLE-ZERO-VAT', @DateFrom = @From, @DateTo = @To;
-- Expect 75 rows, all ProductCode 12050, TotalAmount 950.00 each,
-- EstimatedVATShortfall 101.79 each (950.00 / 1.12 * 0.12).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'SALES-CM-CLIENT', @DateFrom = @From, @DateTo = @To;
-- Expect 26 rows; first hand-verified row: TicketNumber 7237, BranchCode 888,
-- ReferenceNumber 7426, CustomerKey 00000005 (BARITUA, LOURELY), ARValue
-- 9620.00 (traced directly against TicketDetails: Sales(401) debited
-- 9,620.00 / AR(101030101) credited 9,620.00).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'SALES-RETURNED-ORDERS', @DateFrom = @From, @DateTo = @To;
-- Expect 96 rows; PONumber 7426 row (same event as the SALES-CM-CLIENT
-- example above) shows HasGLCreditMemo = 1, TotalAmount 9620.00 (ties
-- exactly to that credit memo's ARValue). Expect 70 of 96 rows with
-- HasGLCreditMemo = 0 (see header "CHECK 5" follow-up finding).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'SALES-CREDIT-LIMIT-BREACH', @DateFrom = @From, @DateTo = @To;
-- BUGFIXED 2026-09-23 — see header "CHECK 6" BUGFIX ADDENDUM.
-- Expect 464 rows (was 860 pre-fix). DeliveryNo 5716, PONumber 5320,
-- CustomerKey 00007492 (LAOHOO, ALVIN CESAR LIM) re-verified under the fix:
-- BalanceAfterOrder now comes back as exactly 792,092.00 (this order's own
-- TotalAmount, looked up directly from its own ClientLedger SI leg) instead
-- of the old, double-counted 2,223,184.00 (1,431,092.00 PriorBalance +
-- 792,092.00 TotalAmount) — OrderAmount 792,092.00 (hand-verified against
-- TransactionChargeSales.ReferenceNo 5320), CreditLimit 50,000.00
-- (hand-verified against Customers), ExcessOverLimit now 742,092.00 (was
-- 2,173,184.00 pre-fix). Also re-verified DeliveryNo 5309, CustomerKey
-- 00001330: BalanceAfterOrder 6,000.00 (this customer's sole invoice in the
-- window, ₱6,000 on 2026-08-01 — was wrongly 12,000.00 pre-fix, the exact
-- double-count the reviewer's proof example describes). 100% of the 464
-- breaching orders belong to default-₱50,000-limit customers (up from
-- 99.5% pre-fix), so Severity=Warning remains correctly justified post-fix.

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'SALES-BELOW-COST', @DateFrom = @From, @DateTo = @To;
-- Expect 577 rows; largest single line: ProductCode 13565 (PORK SHOULDER
-- BONELESS SKINLESS), Cost 213.46, SellingPrice 195.00, Quantity 2218.140,
-- TotalMarginLoss 40946.86 (BranchCode 888, InvoiceNo 'DR 2608-00').

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'NOT-A-REAL-CODE', @DateFrom = @From, @DateTo = @To;
*/
