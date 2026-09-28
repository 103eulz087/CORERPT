# Handoff: Item Costing Recon → Executive Web Reporting Tool

**From:** CORECS ERP (WinForms, `Reporting/ItemCostingReconReport.cs`)
**To:** the ASP.NET Core + Blazor executive/management reporting tool
**Date:** 2026-09-26. Numbers below were read from COREX001 (DEV) and CORECSJFC2026_STAGING on this date.

---

## 1. What this report tells management

When the company imports a shipment (a PO), extra costs arrive afterwards as separate
supplier invoices, such as freight, handling, brokerage and duties. Some of each invoice
belongs in the stock's value. The ERP adds that part to the unit cost of the shipment's stock,
which is its **landed cost**.

The recon answers one question per shipment:

> **Is the unit cost our stock is carried at the same as what the linked expense invoices justify?**

If it isn't, inventory value and cost of sales are wrong by the gap times the quantity. That is why it matters at executive level: it's a direct check on inventory valuation and gross margin.

Drill path the web tool should support (same as the ERP):

```
Executive summary (KPIs)
  └─ Shipments (one row per PO)                          ← result set 1
       └─ Linked expenses of a shipment                  ← result set 2
            └─ GL tickets of one expense (posting, payments, reversals)   ← second SP
                 └─ GL lines of a ticket
```

---

## 2. Data source

Everything comes from **two existing, read-only stored procedures**. Neither writes anything.
The web tool should call them as-is and **must not change them**. The ERP form reads the same
procs by column name, so any change to their columns or result-set order breaks the ERP.
Ask the ERP developer for a new proc instead.

| Proc | Purpose | Speed (measured) |
|---|---|---|
| `dbo.sp_rpt_ItemCostingRecon_List` | Shipments + their linked expenses (2 result sets) | 220–460 ms for the default call |
| `dbo.sp_rpt_ItemCostingRecon_ExpenseTickets` | GL tickets + lines of one expense (2 result sets) | on demand, one expense at a time |

Both are deployed on COREX001 (DEV) and CORECSJFC2026_STAGING as of 2026-09-26.

**Connection:**
- Use the same SQL Server (`corex.itcoreapps.com`) and the same database the ERP uses in that environment. Connect by database name; there is no named instance.
- Use a **dedicated read-only SQL login** with `EXECUTE` on just these two procs. Don't reuse the ERP's login.
- Keep credentials in the web app's secret store (User Secrets / environment variables / Key Vault). **Never** put them in `appsettings.json` or source control.
- The ERP keeps its connection strings DPAPI-encrypted in the Windows registry, per user and per machine. The web tool cannot and should not read them.
- DEV runs compatibility level 160, STAGING 120. Only matters if you write your own SQL; calling the procs is unaffected.

---

## 3. Contract: `sp_rpt_ItemCostingRecon_List`

### Parameters (all optional)

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `@DateFrom` | `DATE` | NULL | PO `DateOrder` from, inclusive. NULL = open-ended |
| `@DateTo` | `DATE` | NULL | PO `DateOrder` to, inclusive (the proc handles the end-of-day) |
| `@ShipmentNo` | `VARCHAR(10)` | NULL | One shipment; NULL or '' = all |
| `@OnlyWithExpenses` | `BIT` | 1 | 1 = only shipments that have at least one linked expense. **Keep it at 1 for the executive view** (see §5) |

### Result set 1: Shipments (one row per PO)

| Column | .NET type | Meaning |
|---|---|---|
| `ShipmentNo` | string | PO / shipment number. **Key**, joins to result set 2 |
| `SupplierID` | string | Supplier code |
| `SupplierName` | string | Supplier name |
| `BranchName` | string | Receiving branch name (e.g. HEAD OFFICE CEBU, CAGAYAN BRANCH). No branch code is returned |
| `Status` | string | PO status: `FOR CONFIRMATION`, `RECEIVED`, `DELIVERED` |
| `DateOrder` | DateTime | PO date (has a time part) |
| `TotalQty` | decimal(18,3) | Sum of `Inventory.Quantity` over the shipment's lots |
| `CurrentMinCost` | decimal(18,4) | Lowest live unit cost across the shipment's lots |
| `CurrentMaxCost` | decimal(18,4) | Highest live unit cost across lots, shown as "Live Unit Cost" |
| `LinkedExpenseCount` | int | Number of linked expense invoices |
| `TotalInvoiceAmount` | decimal(18,2) | Sum of the linked invoices' full amounts. **For reference only**; not everything on an invoice is inventory cost |
| `TotalInventoryCost` | decimal(18,2) | Sum of the part of those invoices that was posted to inventory. **This is what was added to cost** |
| `TotalCostIncorporated` | decimal(18,4) | `TotalInventoryCost ÷ TotalQty`: the unit cost the expenses justify |
| `Variance` | decimal(18,4) | **Per unit:** `CurrentMaxCost − TotalCostIncorporated` |
| `IsMatched` | bool | `abs(Variance) ≤ 0.01` |
| `ReconStatus` | string | See §4 |

Order: `DateOrder DESC, ShipmentNo DESC`.

### Result set 2: Linked expenses (one row per expense invoice)

| Column | .NET type | Meaning |
|---|---|---|
| `ShipmentNo` | string | Key back to result set 1 |
| `ReferenceNumber` | string | Expense reference no. With `InvoiceNo` and `ShipmentNo`, it identifies the expense for the tickets proc |
| `InvoiceNo` | string | Supplier invoice no. |
| `SupplierName` | string | Expense supplier (e.g. the forwarder), which can differ from the PO supplier |
| `ExpenseDate` | DateTime? | Invoice date |
| `Remarks` | string? | Description |
| `Amount` | decimal(18,2) | Full invoice amount (reference) |
| `InventoryCost` | decimal(18,2) | Part posted to inventory (what was costed) |
| `CostDerived` | decimal(18,4)? | `InventoryCost ÷ TotalQty`, the unit cost this invoice added. NULL when the shipment has 0 qty |
| `RunningTotal` | decimal(18,4)? | Cumulative `CostDerived` within the shipment, in date order |

**Tie-out:** the last `RunningTotal` of a shipment equals that shipment's `TotalCostIncorporated`.
Adding up the *rounded* `CostDerived` values yourself can differ from it by a fraction of a cent.
That's expected: the proc sums unrounded values. Show the proc's numbers; don't recompute them.

---

## 4. `ReconStatus`: meaning and colour

The proc applies these **in this order**, so the first one that matches wins:

| Status | Rule | Meaning for management | Suggested colour |
|---|---|---|---|
| `NO EXPENSES` | no linked expense | Nothing to reconcile (normally hidden, see §5) | grey |
| `NO INVENTORY` | total qty = 0 | Expenses exist but no stock was received on the shipment | amber |
| `LOTS DIVERGE` | min vs max lot cost differ > 0.01 | The shipment's lots carry different unit costs. Needs an accountant's look | amber |
| `MATCHED` | abs(Variance) ≤ 0.01 | Stock cost agrees with the expenses | green |
| `VARIANCE` | anything else | Stock cost disagrees with the expenses | red |

Why a shipment shows `VARIANCE` (from the ERP side):
- Costing was done before the 2026-09-24 fix, which wrongly costed the **whole invoice** instead of only its inventory part.
  Historical `Inventory.Cost` was **not** corrected; that is an open decision with the ERP owner.
- A manual cost override.
- Final cost confirmation on the PO.
- A linked expense edited after posting.

**Sign of Variance:**
- **Positive:** stock carries **more** unit cost than the expenses justify, so inventory is likely overstated.
- **Negative:** stock carries **less**, so inventory is likely understated.

---

## 5. Suggested executive view

Load result set 1 with `@OnlyWithExpenses = 1` and compute everything below **in the web app**.
The data is small (45 shipments / 180 expenses in the current data), so no extra proc is needed.
If volume grows a lot, ask the ERP side for a summary proc rather than aggregating millions of rows in the browser.

### KPI tiles

| KPI | Formula (over result set 1, `@OnlyWithExpenses = 1`) |
|---|---|
| Shipments reconciled | count of rows |
| Match rate | `count(MATCHED) ÷ count(rows)` |
| Shipments needing attention | `count(ReconStatus IN ('VARIANCE','LOTS DIVERGE','NO INVENTORY'))` |
| Inventory cost from expenses | `sum(TotalInventoryCost)` |
| **Net variance value** | `sum(Variance × TotalQty)` over `VARIANCE` rows |
| **Gross variance exposure** | `sum(abs(Variance × TotalQty))` over `VARIANCE` rows. Show it next to the net figure, because over- and under-costing cancel out in the net |

`Variance × TotalQty` is a **derived** figure; the proc doesn't return it. It is the money impact on
the whole received batch, based on `Inventory.Quantity`, not on stock still on hand.
Label it "variance value (received qty)" so no one reads it as a P&L number.

**Never include `NO EXPENSES` rows in variance KPIs.** With no expenses, the "variance" is just
the full live unit cost. With `@OnlyWithExpenses = 0` those rows add ~406M of meaningless
"variance" on DEV.

### Charts and lists
- Status breakdown (donut or stacked bar): MATCHED / VARIANCE / LOTS DIVERGE / NO INVENTORY.
- **Top 10 shipments by `abs(Variance × TotalQty)`**, with supplier, PO status and branch. This is the "where to look first" list.
- Variance value by supplier, and by `BranchName`.
- Optional: split by PO `Status`. A `FOR CONFIRMATION` shipment's final cost may still change, so a variance there is less settled than one on a `RECEIVED` shipment.

### Filters
- PO date range (`@DateFrom` / `@DateTo`). The ERP defaults to the start of last month through today.
- Shipment (`@ShipmentNo`).
- Status / supplier / branch: filter in the web app on result set 1; the proc has no parameters for these.

---

## 6. Drill-down: `sp_rpt_ItemCostingRecon_ExpenseTickets`

Call it when the user opens one expense row from result set 2.

### Parameters (all required)

| Parameter | Type | Take from result set 2 |
|---|---|---|
| `@ReferenceNumber` | `VARCHAR(10)` | `ReferenceNumber` |
| `@InvoiceNo` | `VARCHAR(150)` | `InvoiceNo` |
| `@ShipmentNo` | `VARCHAR(10)` | `ShipmentNo` |

### Result set 1: Tickets

| Column | .NET type | Meaning |
|---|---|---|
| `TicketNumber` | string | GL ticket no. Key with `ReferenceNumber` |
| `ReferenceNumber` | string | Key with `TicketNumber` (a ticket number alone is not unique) |
| `ReferenceKey` | string? | Invoice no. (posting) or voucher ID (payment) |
| `TicketDate` | DateTime | Ticket date |
| `Source` | string | `EXPENSE POSTING`, `PAYMENT`, or `PAYMENT REVERSAL` |
| `VoucherType` | string? | `CASH` / `CHECK` / `TELEGRAPHIC` for payments; NULL for the posting |
| `Mnemonic` | string | ERP posting type (e.g. `SINGLE`, `SINGLE-PAY`) |
| `Status` | string | Ticket status |
| `Particulars` | string | Ticket description (can be long; truncate in the UI) |
| `TotalDebit` / `TotalCredit` | decimal(18,2) | Ticket totals; they are always equal |

Order: posting first, then payments, then reversals, each by date.

### Result set 2: Lines

| Column | .NET type | Meaning |
|---|---|---|
| `TicketNumber`, `ReferenceNumber` | string | Composite key back to result set 1 |
| `BranchCode` | string | Branch code |
| `Account` | string | Already formatted as `Code - Description` (e.g. `101040201 - INVENTORY - VAT EXEMPT`) |
| `Debit` / `Credit` | decimal(18,2) | Amounts |
| `Particulars` | string? | Line description |

A payment voucher's ticket is shown **whole**. If that voucher also paid other invoices, their lines
appear too. Show a one-line note saying so, as the ERP popup does.

For executives this level is probably "view only on request". Put it behind a click; don't load it by default.

---

## 7. Implementation notes (ASP.NET Core / Blazor)

- **Server-side only:** call the procs from a server service (Blazor Server, or an API that Blazor WASM calls). Never open a SQL connection from the browser.
- **Multiple result sets:** read both result sets from one call, in order (Dapper `QueryMultipleAsync`, or `SqlDataReader.NextResultAsync`). Result-set order is part of the contract.
- **Parameter types:** declare them explicitly with the sizes above, not `AddWithValue`. Pass `DBNull.Value` for an omitted filter.
- **Timeout:** the ERP uses a `CommandTimeout` of 300 s for the list. It's far faster today, but keep a generous timeout.
- **Caching:** the data changes only when expenses or payments are posted. A 5–15 minute server-side cache per filter set is plenty for a management dashboard.
- **Number formats:**
  - Money: 2 dp (`N2`).
  - Unit costs and variance per unit: 4 dp (`N4`).
  - Quantities: 3 dp (`N3`).
  - Keep values `decimal` all the way through; never `double`.
  - Right-align numeric columns.
- **Codes and names:** the ERP shows `Code - Name` in dropdowns and grids (e.g. supplier `SupplierID - SupplierName`). Keep that for consistency.

Sketch (Dapper + `Microsoft.Data.SqlClient`; adapt to your data layer):

```csharp
public sealed record ReconShipment(
    string ShipmentNo, string SupplierID, string SupplierName, string BranchName,
    string Status, DateTime? DateOrder, decimal TotalQty,
    decimal CurrentMinCost, decimal CurrentMaxCost, int LinkedExpenseCount,
    decimal TotalInvoiceAmount, decimal TotalInventoryCost,
    decimal TotalCostIncorporated, decimal Variance, bool IsMatched, string ReconStatus)
{
    public decimal VarianceValue => Variance * TotalQty;   // derived, see §5
}

public sealed record ReconExpense(
    string ShipmentNo, string ReferenceNumber, string InvoiceNo, string SupplierName,
    DateTime? ExpenseDate, string? Remarks, decimal Amount, decimal InventoryCost,
    decimal? CostDerived, decimal? RunningTotal);

public async Task<(IReadOnlyList<ReconShipment> Shipments, IReadOnlyList<ReconExpense> Expenses)>
    GetReconAsync(DateTime? from, DateTime? to, string? shipmentNo, CancellationToken ct)
{
    var p = new DynamicParameters();
    p.Add("@DateFrom", from?.Date, DbType.Date);
    p.Add("@DateTo", to?.Date, DbType.Date);
    p.Add("@ShipmentNo", string.IsNullOrWhiteSpace(shipmentNo) ? null : shipmentNo, DbType.AnsiString, size: 10);
    p.Add("@OnlyWithExpenses", true, DbType.Boolean);

    await using var con = new SqlConnection(_connectionString);   // read-only login
    using var grid = await con.QueryMultipleAsync(new CommandDefinition(
        "dbo.sp_rpt_ItemCostingRecon_List", p,
        commandType: CommandType.StoredProcedure, commandTimeout: 300, cancellationToken: ct));

    var shipments = (await grid.ReadAsync<ReconShipment>()).ToList();   // result set 1
    var expenses  = (await grid.ReadAsync<ReconExpense>()).ToList();    // result set 2
    return (shipments, expenses);
}
```

Records with positional constructors need the column order to match for Dapper. If your Dapper
version complains, switch to classes with settable properties, which map by name.

---

## 8. Test values (use them to check your dashboard)

Default call (`@OnlyWithExpenses = 1`, no date filter). DEV and STAGING currently return the same
shipments and amounts; only the PO `Status` split differs.

| Check | Expected |
|---|---|
| Shipments / expense rows | 45 / 180 |
| MATCHED / VARIANCE | 6 / 39 (no LOTS DIVERGE or NO INVENTORY right now) |
| VARIANCE rows with positive / negative variance | 26 / 13 |
| `sum(TotalInventoryCost)`, MATCHED + VARIANCE | 118,710,823.15 (13,740,789.09 + 104,970,034.06) |
| Net variance value, VARIANCE rows | ≈ 2,112,259.06 |
| Top shipment by abs variance value | 10955 · PROFOOD NETHERLANDS · 27,250.000 qty · +82.7663/unit · ≈ 2,255,381.68 |
| Next ones | 11001 (≈ −347,233.56), 11000 (≈ −341,889.75), 10992 (≈ +287,281.92), 10968 (≈ +282,461.76) |
| By branch | HEAD OFFICE CEBU 16 · CAGAYAN 15 · DAVAO 12 · POLOMOLOK 2 |
| Tickets drill-down, expense `18578` / `SI-202630196` / shipment `10958` | 4 tickets: posting 7727, payments 8369 and 8957, reversal 8956 |
| Tickets drill-down, expense `24161` / `SI-202630244` / shipment `10992` | 2 tickets: posting 10669, payment 10827 |

Figures move as new expenses post, so they are a snapshot for 2026-09-26, not constants.

---

## 9. Things to tell management with the dashboard

- **Most shipments show VARIANCE today (39 of 45).** Most of this is expected to come from the old whole-invoice costing, fixed on 2026-09-24 going forward.
  The historical unit costs were not re-stated. Put a short caption on the dashboard so a red board isn't read as 39 new problems.
- **The variance value is not a P&L figure.** It is the size of the valuation gap on the received batch. Some of that stock may already be sold, and the gap then sits in cost of sales, not in inventory.
- `FOR CONFIRMATION` shipments can still have their final cost confirmed, so their variance may still change.

---

## 10. Open questions for the owner

1. Which database should the web tool read in production: CORECSJFC2026_STAGING, or a separate production database?
2. Who gets the dashboard, and should it be filtered by branch per user? The procs return all branches; any per-user restriction has to be applied in the web app.
3. Is `Variance × TotalQty` (received qty) the right "value" figure for management, or do they want it on **stock still on hand** (`Available`)? The second would need a new proc from the ERP side.
4. Should the dashboard wait until the historical cost correction is decided (ERP open decision #4)? Otherwise the caption in §9 is essential.
