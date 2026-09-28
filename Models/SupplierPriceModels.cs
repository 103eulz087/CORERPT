namespace CoreReporting.Models;

/* ============================================================================
   Supplier Price Comparison — landed cost per kg by supplier, bucketed
   weekly / monthly / yearly. One DTO per result set of
   dbo.sp_rpt_SupplierPriceComparison (sql/29-supplier-price-comparison.sql),
   in the proc's result-set order.

   Basis: SUM(linked ExpenseSummary.Amount) / SUM(PODETAILS.ActualQuantity).
   That is the INVOICE basis (includes recoverable VAT and any invoice lines
   not capitalised to inventory). The inventory-costed basis comes from the
   ERP's own sp_rpt_ItemCostingRecon_List and is joined per shipment in
   SupplierPriceService, never recomputed.
============================================================================ */

/// <summary>Period grain the proc buckets DateOrder into.</summary>
public enum PricePeriod
{
    Weekly,
    Monthly,
    Yearly
}

public static class PricePeriodExtensions
{
    /// <summary>The proc's @Period code.</summary>
    public static string Code(this PricePeriod p) => p switch
    {
        PricePeriod.Weekly => "W",
        PricePeriod.Yearly => "Y",
        _ => "M"
    };

    public static string Label(this PricePeriod p) => p switch
    {
        PricePeriod.Weekly => "Weekly",
        PricePeriod.Yearly => "Yearly",
        _ => "Monthly"
    };

    public static PricePeriod Parse(string? s) => (s ?? "").Trim().ToUpperInvariant() switch
    {
        "W" or "WEEK" or "WEEKLY" => PricePeriod.Weekly,
        "Y" or "YEAR" or "YEARLY" or "ANNUAL" => PricePeriod.Yearly,
        _ => PricePeriod.Monthly
    };
}

/// <summary>Result set 1 — one PO (shipment) with at least one linked invoice.</summary>
public sealed class PriceShipmentRow
{
    public string ShipmentNo { get; set; } = "";
    public string BranchCode { get; set; } = "";      // varchar, never int (Hard Rule #2)
    public string BranchName { get; set; } = "";
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public string PoStatus { get; set; } = "";
    public DateTime DateOrder { get; set; }
    public DateTime PeriodStart { get; set; }
    public string PeriodLabel { get; set; } = "";
    public decimal OrderedKg { get; set; }
    public decimal ReceivedKg { get; set; }
    public int ProductCount { get; set; }
    public string ProductCode { get; set; } = "";      // blank unless single-product
    public string ProductDescription { get; set; } = "";
    public bool IsMultiProduct { get; set; }
    public int ExpenseCount { get; set; }
    public int UnpostedExpenseCount { get; set; }
    public decimal SupplierInvoiceAmount { get; set; }
    public decimal AddOnAmount { get; set; }
    public decimal TotalLandedAmount { get; set; }
    public decimal? SupplierPricePerKg { get; set; }
    public decimal? AddOnPerKg { get; set; }
    public decimal? LandedCostPerKg { get; set; }      // null when nothing received yet
    public string PriceStatus { get; set; } = "";      // PRICED / NOT RECEIVED

    /* ---- Cross-check against sp_rpt_ItemCostingRecon_List, filled in by
       SupplierPriceService (NOT returned by sp_rpt_SupplierPriceComparison). ---- */

    /// <summary>Recon's TotalCostIncorporated: the part of the invoices
    /// actually capitalised to inventory, per unit. Null when the recon has
    /// no row for this shipment or was unavailable.</summary>
    public decimal? InventoryCostedPerKg { get; set; }

    /// <summary>Recon's TotalInvoiceAmount for the same shipment.</summary>
    public decimal? ReconInvoiceAmount { get; set; }

    /// <summary>MATCHES / DIFFERS / NOT IN RECON / UNAVAILABLE — whether this
    /// report found the same invoices the ERP recon links to the shipment.</summary>
    public string LinkCheck { get; set; } = "";
}

/// <summary>Result set 2 — one (period, PO supplier), priced shipments only.
/// All ₱/kg figures are weighted: SUM(amount) / SUM(kg).</summary>
public sealed class SupplierPeriodRow
{
    public DateTime PeriodStart { get; set; }
    public string PeriodLabel { get; set; } = "";
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public int Shipments { get; set; }
    public int MixedShipments { get; set; }
    public decimal ReceivedKg { get; set; }
    public decimal SupplierInvoiceAmount { get; set; }
    public decimal AddOnAmount { get; set; }
    public decimal TotalLandedAmount { get; set; }
    public decimal LandedCostPerKg { get; set; }
    public decimal SupplierPricePerKg { get; set; }
    public decimal AddOnPerKg { get; set; }
    public decimal MinShipmentPerKg { get; set; }
    public decimal MaxShipmentPerKg { get; set; }
    public decimal? PeriodAvgPerKg { get; set; }
    public decimal? VsPeriodAvgPct { get; set; }
    public int RankInPeriod { get; set; }
    public int SuppliersInPeriod { get; set; }
    /// <summary>The previous period in which THIS supplier had a priced
    /// shipment — not necessarily the adjacent calendar period.</summary>
    public DateTime? PrevPeriodStart { get; set; }
    public decimal? PrevLandedPerKg { get; set; }
    public decimal? ChangePct { get; set; }
}

/// <summary>Result set 3 — one (period, product, supplier), SINGLE-product
/// shipments only: the like-for-like comparison.</summary>
public sealed class ProductPeriodRow
{
    public DateTime PeriodStart { get; set; }
    public string PeriodLabel { get; set; } = "";
    public string ProductCode { get; set; } = "";
    public string ProductDescription { get; set; } = "";
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public int Shipments { get; set; }
    public decimal ReceivedKg { get; set; }
    public decimal TotalLandedAmount { get; set; }
    public decimal LandedCostPerKg { get; set; }
    public decimal SupplierPricePerKg { get; set; }
    public decimal BestPerKg { get; set; }
    public decimal? VsBestPct { get; set; }
    public int RankForProduct { get; set; }
    public int SuppliersForProduct { get; set; }
    public DateTime? PrevPeriodStart { get; set; }
    public decimal? PrevLandedPerKg { get; set; }
    public decimal? ChangePct { get; set; }
}

/// <summary>Result set 4 — one linked ExpenseSummary invoice.</summary>
public sealed class PriceExpenseRow
{
    public string ShipmentNo { get; set; } = "";
    public string ReferenceNumber { get; set; } = "";
    public string InvoiceNo { get; set; } = "";
    public string ExpenseSupplierId { get; set; } = "";
    public string ExpenseSupplierName { get; set; } = "";
    public DateTime? ExpenseDate { get; set; }
    public string Description { get; set; } = "";
    public string ExpenseStatus { get; set; } = "";
    public bool IsPostedToGl { get; set; }
    public decimal Amount { get; set; }
    /// <summary>SUPPLIER (the PO supplier's own invoice) or ADD-ON (freight,
    /// broker, customs, trucking...). Heuristic by SupplierID, see sql/29 #4.</summary>
    public string CostRole { get; set; } = "";
}

public sealed class SupplierPriceResult
{
    public IReadOnlyList<PriceShipmentRow> Shipments { get; set; } = Array.Empty<PriceShipmentRow>();
    public IReadOnlyList<SupplierPeriodRow> SupplierPeriods { get; set; } = Array.Empty<SupplierPeriodRow>();
    public IReadOnlyList<ProductPeriodRow> ProductPeriods { get; set; } = Array.Empty<ProductPeriodRow>();
    public IReadOnlyList<PriceExpenseRow> Expenses { get; set; } = Array.Empty<PriceExpenseRow>();
}

/// <summary>Whole-range, per-supplier rollup computed in C# from the
/// shipment rows (weighted, priced shipments only) — the "who is cheapest
/// over the whole range" ranking.</summary>
public sealed class SupplierRangeRow
{
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public int Shipments { get; set; }
    public int MixedShipments { get; set; }
    public decimal ReceivedKg { get; set; }
    public decimal TotalLandedAmount { get; set; }
    public decimal SupplierInvoiceAmount { get; set; }
    public decimal AddOnAmount { get; set; }
    public decimal LandedCostPerKg => ReceivedKg == 0 ? 0 : TotalLandedAmount / ReceivedKg;
    public decimal SupplierPricePerKg => ReceivedKg == 0 ? 0 : SupplierInvoiceAmount / ReceivedKg;
    public decimal AddOnPerKg => ReceivedKg == 0 ? 0 : AddOnAmount / ReceivedKg;
}

public sealed class SupplierPriceViewModel
{
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }
    public PricePeriod Period { get; set; }
    public string? ProductCode { get; set; }

    public SupplierPriceResult Data { get; set; } = new();
    public IReadOnlyList<SupplierRangeRow> SupplierRange { get; set; } = Array.Empty<SupplierRangeRow>();

    /* ---- KPI tiles (priced shipments only unless noted) ---- */
    public int PricedShipments { get; set; }
    public int NotReceivedShipments { get; set; }
    public int MixedShipments { get; set; }
    public decimal ReceivedKg { get; set; }
    public decimal TotalLandedAmount { get; set; }
    public decimal? WeightedLandedPerKg { get; set; }
    public decimal? AddOnSharePct { get; set; }
    public int UnpostedInvoices { get; set; }

    /// <summary>False when sp_rpt_ItemCostingRecon_List could not be read
    /// (e.g. not deployed on the target DB) — the page then says so instead
    /// of showing an empty inventory-costed column as if it were zero.</summary>
    public bool ReconCrossCheckAvailable { get; set; }
    public int LinkDiffers { get; set; }

    public DateTime GeneratedAt { get; set; }
}
