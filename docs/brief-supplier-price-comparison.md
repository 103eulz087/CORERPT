# Brief — Supplier Price Comparison

**Module:** Purchasing · **Route:** `/SupplierPrice/Index` · **Roles:** Executive, Accounting, Audit, Operations
**Proc:** `dbo.sp_rpt_SupplierPriceComparison` (`sql/29-supplier-price-comparison.sql`)
**Status (2026-09-29):** built and compiled, rendered against fake data. **Not yet applied to COREX001 or smoke-tested against real data.** The authoring session couldn't reach the DB server.

---

## The ask

The client wants a report on supplier pricing, weekly, monthly and yearly, so they can compare suppliers and analyse how prices move.

PO lines (`POSUMMARY`/`PODETAILS`) carry quantity but no cost: `PODETAILS.Cost` is 0 on every live row (`sql/19`). The money is entered afterwards as `ExpenseSummary` invoices tagged with the PO's `ShipmentNo`. So:

```
landed cost per kg = SUM(linked ExpenseSummary.Amount) / SUM(PODETAILS.ActualQuantity)
```

## What the report shows

| Section | Grain | Use |
|---|---|---|
| KPI tiles | whole range | weighted ₱/kg, kilos, total landed cost, add-on share |
| Trend chart | supplier × period | is a supplier getting dearer? (top 6 suppliers by kg) |
| Ranking chart | supplier, whole range | cheapest first; supplier invoice vs add-ons stacked |
| By supplier and period | supplier × period | rank in period, vs period average, change vs previous priced period |
| **By product (like-for-like)** | product × supplier × period | the only fair price comparison (see caveat 3) |
| Shipments | one per PO | ₱/kg per shipment, ERP inventory-costed ₱/kg beside it, link check; click a row for its invoices |
| Excel export | all four result sets | one sheet each, with autofilter, for the client's own pivots |

Hey Jude intent: `supplier_price_comparison` ("which supplier was cheapest per kilo this year?").

## Insights / caveats (why the report is built the way it is)

1. **These are landed costs paid, not quotations.** No ERP table records a supplier's offer before the PO. If the client wants true offer-vs-offer comparison (including suppliers they didn't buy from), they need a quotation table. That's an ERP change. This report can only compare what was actually bought.
2. **Invoice basis includes VAT.** `ExpenseSummary.Amount` is the full invoice, which includes recoverable input VAT (e.g. import VAT paid through the broker) and any invoice lines that weren't capitalised. That's the client's formula and the right "cash cost" view. The shipments table also shows the ERP recon's **inventory-costed ₱/kg**, so a supplier who only *looks* dearer because of VAT is visible.
3. **Supplier-level ranks aren't like-for-like, and mixed-product POs can't be priced per product.** Supplier-level ranks compare whatever each supplier shipped (beef vs pork). Also, PO lines have no cost, so a PO with belly and shoulder gets one blended ₱/kg. A supplier who ships mostly premium cuts will look "expensive" at supplier level. The **By product** table therefore uses **single-product shipments only** and never allocates by kg, since that would assume every cut costs the same.
4. **Supplier price vs add-ons.** Invoices from the PO's own supplier are tagged `SUPPLIER` (the price offer). Everything else (forwarder, broker, customs, trucking) is tagged `ADD-ON`. Add-ons move with freight and FX, not with the supplier, so negotiating with a supplier should look at the supplier ₱/kg, not the landed figure. This split is a heuristic: if a supplier invoice is booked under an agent's SupplierID, it lands in add-ons. The total is unaffected.
5. **Weighted, not averaged.** Every ₱/kg is `SUM(₱) / SUM(kg)`. A 500 kg trial order doesn't move a supplier's figure as much as a 27-tonne container does.
6. **Only fully invoiced, received shipments are priced.** Every shipment is listed, but only `PRICED` ones enter a ₱/kg or an average. `NOT RECEIVED` means invoices but 0 kg received (never divided by ordered kg). `INCOMPLETE` means kilos received but no invoice from the PO supplier yet; only freight/broker so far, which would look far too cheap. `NO PO LINES` means no PODETAILS at all, e.g. the DELIVERED migration batch.
7. **Period = PO order date.** The price is agreed at order time. Invoices often post weeks later, so a recent period can look cheap simply because its add-on invoices haven't arrived yet. Treat the last period or two as provisional.
8. **FX is invisible.** Amounts are in pesos (this ERP has no FX tracking, see `sql/25`). A ₱/kg rise can be the peso weakening rather than the supplier raising prices. The report can't separate the two.

## Review

The accounting-reviewer ran over the first version (2026-09-29). Fixed from that pass:
- INCOMPLETE / NO PO LINES statuses.
- The product filter keeps only single-product shipments of that product.
- The inventory-costed ₱/kg is recomputed on the same received-kg base.
- The link check now compares invoice count as well as total, and flags duplicate recon rows.
- Monday-snapped weekly default.
- Captions for cross-product ranks, provisional latest periods and FOR CONFIRMATION.
- Hey Jude caveats: cross-product ranking, incomplete and unposted invoices, and the period movement.
- NULLIF guards.

Still open, needs the live DB: gross-vs-net check (`sql/29` smoke test E), whether goods cost is ever booked in APAccounts (test F), and cancelled/void status values.

## Open questions for the developer

1. `SELECT DISTINCT Status FROM ExpenseSummary`: which values mean cancelled/void? (The proc currently excludes anything containing CANCEL or VOID.)
2. Does `ExpenseSummary.ShipmentNo` carry the same link the ERP recon uses? The **Link check** column shows it per shipment (`DIFFERS` = the two disagree).
3. Is the meat supplier's own invoice booked under the PO's SupplierID? If not, the supplier/add-on split needs another rule (expense type or GL account).
4. Should the `DELIVERED` migration batch (`sql/19`: ShipmentNo 00001–00320, all stamped 2026-09-07) be excluded? If those POs have linked invoices, they all fall into one week/month with a fake order date.
5. Should supplier discounts taken at payment (`DiscountWithheld`) lower the landed cost? Today they don't.
6. Does the client want a quotation table added to the ERP, for true offer comparison?
