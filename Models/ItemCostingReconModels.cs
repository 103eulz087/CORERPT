namespace CoreReporting.Models;

/// <summary>One row of sp_rpt_ItemCostingRecon_List result set 1 — one
/// shipment (PO) and whether its carried unit cost agrees with the linked
/// expense invoices that were posted to inventory. See
/// docs/ItemCostingRecon_WebReporting_Handoff.md for the full business
/// meaning and the ReconStatus rule order.</summary>
public sealed class ReconShipmentRow
{
    public string ShipmentNo { get; set; } = "";
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public string BranchName { get; set; } = "";
    public string Status { get; set; } = "";           // PO status: FOR CONFIRMATION / RECEIVED / DELIVERED
    public DateTime DateOrder { get; set; }
    public decimal TotalQty { get; set; }
    public decimal CurrentMinCost { get; set; }
    public decimal CurrentMaxCost { get; set; }        // "Live Unit Cost" per the handoff doc
    public int LinkedExpenseCount { get; set; }
    public decimal TotalInvoiceAmount { get; set; }
    public decimal TotalInventoryCost { get; set; }
    public decimal TotalCostIncorporated { get; set; }
    public decimal Variance { get; set; }              // per-unit: CurrentMaxCost - TotalCostIncorporated
    public bool IsMatched { get; set; }
    public string ReconStatus { get; set; } = "";      // NO EXPENSES / NO INVENTORY / LOTS DIVERGE / MATCHED / VARIANCE

    /// <summary>Derived here, NOT returned by the proc — see handoff doc §5:
    /// the money impact on the WHOLE RECEIVED BATCH (Inventory.Quantity), not
    /// stock still on hand. Never present this as a P&amp;L figure anywhere
    /// downstream.</summary>
    public decimal VarianceValue => Variance * TotalQty;
}

/// <summary>One row of sp_rpt_ItemCostingRecon_List result set 2 — one
/// linked expense invoice of a shipment.</summary>
public sealed class ReconExpenseRow
{
    public string ShipmentNo { get; set; } = "";
    public string ReferenceNumber { get; set; } = "";
    public string InvoiceNo { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public DateTime? ExpenseDate { get; set; }
    public string? Remarks { get; set; }
    public decimal Amount { get; set; }
    public decimal InventoryCost { get; set; }
    public decimal? CostDerived { get; set; }
    public decimal? RunningTotal { get; set; }
}

/// <summary>Everything the Item Costing Recon dashboard needs, in one
/// payload. KPIs computed in C# per handoff doc §5's exact formulas —
/// never recomputed client-side from raw rows differently.</summary>
public sealed class ItemCostingReconViewModel
{
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }
    public string? ShipmentNo { get; set; }

    public IReadOnlyList<ReconShipmentRow> Shipments { get; set; } = Array.Empty<ReconShipmentRow>();
    public IReadOnlyList<ReconExpenseRow> Expenses { get; set; } = Array.Empty<ReconExpenseRow>();

    public int ShipmentsReconciled { get; set; }
    public decimal MatchRatePct { get; set; }
    public int ShipmentsNeedingAttention { get; set; }
    public decimal InventoryCostFromExpenses { get; set; }
    /// <summary>sum(Variance * TotalQty) over VARIANCE rows ONLY (handoff doc §5) — never all rows.</summary>
    public decimal NetVarianceValue { get; set; }
    /// <summary>sum(abs(Variance * TotalQty)) over VARIANCE rows ONLY.</summary>
    public decimal GrossVarianceExposure { get; set; }

    public DateTime GeneratedAt { get; set; }
}
