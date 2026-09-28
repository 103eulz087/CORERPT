/* ============================================================================
   CORE REPORTING PORTAL — item-costing-recon.js

   Item Costing Recon has NO polling JSON endpoint — the Refresh button on
   Views/ItemCostingRecon/Index.cshtml is a plain server-rendered link that
   reloads the page with the same query string plus &force=true. So there is
   only ONE casing to deal with here: window.CORE_SHIPMENTS / CORE_EXPENSES
   are embedded via @Html.Raw(JsonSerializer.Serialize(...)) with no naming
   policy, i.e. exact C# PascalCase (ShipmentNo, VarianceValue, ...). Read
   them directly — do NOT add exec-dashboard.js's dual-casing g() helper here,
   it would be solving a casing problem this page doesn't have.

   Drives:
   - four client-side filter <select>s over the already-rendered shipments
     table (the underlying proc has no params for these — see the handoff
     doc's §5 "Filters"), toggling row visibility only, no re-fetch;
   - expand/collapse of a shipment row into its linked-expenses sub-table,
     filtered client-side out of window.CORE_EXPENSES (all 180 rows already
     on the page — no extra fetch);
   - the shared CoreDrilldownModal (drilldown-modal.js) wired to
     /ItemCostingRecon/TicketsDrilldown for the GL tickets/lines drilldown,
     the fourth consumer of that factory after Health Check, Exception
     Center and Report Center;
   - the four ECharts (status breakdown, top 10 by |variance value|,
     variance by supplier, variance by branch), all aggregated client-side
     from window.CORE_SHIPMENTS.
============================================================================ */
(function () {
    "use strict";

    var BRINE = "#3B82F6", CUT = "#F87171", STEEL = "#94A3B8",
        TALLOW = "#FBBF24", LINE = "#334155", GOOD = "#34D399";

    var FILTER_IDS = ["icrFilterStatus", "icrFilterSupplier", "icrFilterBranch", "icrFilterReconStatus"];

    var statusChart, top10Chart, supplierChart, branchChart, modal;

    function $(id) { return document.getElementById(id); }

    function escHtml(s) {
        return window.CoreDrilldownModal ? window.CoreDrilldownModal.escapeHtml(s) : String(s == null ? "" : s);
    }

    /* ---------------- number formatting ---------------- */

    // Money, 2dp, negatives in parentheses (never a bare minus — same
    // convention as the statement views' .neg class, reused here for the
    // client-rendered chart tooltips/lists/sub-table).
    function peso(v) {
        var n = Number(v) || 0;
        var formatted = "₱" + Math.abs(n).toLocaleString("en-PH",
            { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        return n < 0 ? "(" + formatted + ")" : formatted;
    }

    // Unit cost / variance-per-unit, 4dp. Never coerce a null to 0 — show
    // an em-dash instead (CostDerived/RunningTotal can be legitimately null
    // per the handoff doc §3, and the proc's own rounding means a naive
    // re-sum of these can differ from RunningTotal by a fraction of a cent
    // — display exactly what the row says, don't recompute).
    function fmt4(v) {
        if (v === null || v === undefined) return "–";
        return Number(v).toLocaleString("en-PH", { minimumFractionDigits: 4, maximumFractionDigits: 4 });
    }

    function fmtDateOnly(v) {
        if (!v) return "–";
        return String(v).slice(0, 10);
    }

    /* ---------------- client-side filters over the rendered table ---------------- */

    function applyFilters() {
        var statusVal = $("icrFilterStatus") ? $("icrFilterStatus").value : "";
        var supplierVal = $("icrFilterSupplier") ? $("icrFilterSupplier").value : "";
        var branchVal = $("icrFilterBranch") ? $("icrFilterBranch").value : "";
        var reconVal = $("icrFilterReconStatus") ? $("icrFilterReconStatus").value : "";

        var rows = document.querySelectorAll("#icrShipmentBody tr.icr-ship-row");
        var anyVisible = false;

        rows.forEach(function (tr) {
            var match =
                (!statusVal || tr.getAttribute("data-status") === statusVal) &&
                (!supplierVal || tr.getAttribute("data-supplier") === supplierVal) &&
                (!branchVal || tr.getAttribute("data-branch") === branchVal) &&
                (!reconVal || tr.getAttribute("data-reconstatus") === reconVal);

            tr.style.display = match ? "" : "none";
            if (match) anyVisible = true;

            // Keep an open expense sub-row in lockstep with its owning
            // shipment row's visibility (it's always the immediate next
            // sibling while expanded — see toggleShipmentRow).
            var next = tr.nextElementSibling;
            if (next && next.classList.contains("icr-expense-row")) {
                next.style.display = match ? "" : "none";
            }
        });

        var emptyMsg = $("icrEmptyMsg");
        if (emptyMsg) emptyMsg.style.display = anyVisible ? "none" : "";
    }

    function wireFilters() {
        FILTER_IDS.forEach(function (id) {
            var el = $(id);
            if (el) el.addEventListener("change", applyFilters);
        });
        var clearBtn = $("icrClearFilters");
        if (clearBtn) {
            clearBtn.addEventListener("click", function () {
                FILTER_IDS.forEach(function (id) {
                    var el = $(id);
                    if (el) el.value = "";
                });
                applyFilters();
            });
        }
    }

    /* ---------------- shipment -> linked expenses expand/collapse ---------------- */

    function buildExpenseTable(expenses, shipmentNo) {
        var wrap = document.createElement("div");
        wrap.className = "icr-subtable-wrap";

        var rowsHtml;
        if (!expenses.length) {
            rowsHtml = "<tr><td class=\"hc-empty-row\" colspan=\"8\">No linked expenses.</td></tr>";
        } else {
            rowsHtml = expenses.map(function (e) {
                var refNum = e.ReferenceNumber == null ? "" : String(e.ReferenceNumber);
                var invNo = e.InvoiceNo == null ? "" : String(e.InvoiceNo);
                return "<tr class=\"icr-exp-row hc-row-clickable\" tabindex=\"0\" role=\"button\"" +
                    " aria-label=\"View GL tickets for invoice " + escHtml(invNo) + "\"" +
                    " data-refnum=\"" + escHtml(refNum) + "\"" +
                    " data-invoiceno=\"" + escHtml(invNo) + "\"" +
                    " data-shipmentno=\"" + escHtml(shipmentNo) + "\">" +
                    "<td class=\"mono\">" + escHtml(refNum) + "</td>" +
                    "<td class=\"mono\">" + escHtml(invNo) + "</td>" +
                    "<td>" + escHtml(e.SupplierName) + "</td>" +
                    "<td class=\"mono\">" + fmtDateOnly(e.ExpenseDate) + "</td>" +
                    "<td class=\"n mono\">" + peso(e.Amount) + "</td>" +
                    "<td class=\"n mono\">" + peso(e.InventoryCost) + "</td>" +
                    "<td class=\"n mono\">" + fmt4(e.CostDerived) + "</td>" +
                    "<td class=\"n mono\">" + fmt4(e.RunningTotal) + "</td>" +
                    "</tr>";
            }).join("");
        }

        wrap.innerHTML =
            "<table><thead><tr>" +
            "<th>Reference</th><th>Invoice no.</th><th>Supplier</th><th>Expense date</th>" +
            "<th class=\"n\">Amount</th><th class=\"n\">Inventory cost</th>" +
            "<th class=\"n\">Cost derived</th><th class=\"n\">Running total</th>" +
            "</tr></thead><tbody>" + rowsHtml + "</tbody></table>";

        if (modal) {
            var expRows = wrap.querySelectorAll("tr.icr-exp-row");
            window.CoreDrilldownModal.wireClickableElements(expRows, function (el) {
                var invNo = el.getAttribute("data-invoiceno");
                var refNum = el.getAttribute("data-refnum");
                modal.open(
                    { referenceNumber: refNum, invoiceNo: invNo, shipmentNo: shipmentNo },
                    "Invoice " + invNo + " — Shipment " + shipmentNo
                );
            });
        }

        return wrap;
    }

    function toggleShipmentRow(tr) {
        var shipmentNo = tr.getAttribute("data-shipment");
        var next = tr.nextElementSibling;

        if (next && next.classList.contains("icr-expense-row")) {
            next.parentNode.removeChild(next);
            tr.setAttribute("aria-expanded", "false");
            return;
        }

        var expenses = (window.CORE_EXPENSES || []).filter(function (e) {
            return e.ShipmentNo === shipmentNo;
        });

        var detailRow = document.createElement("tr");
        detailRow.className = "icr-expense-row";
        var td = document.createElement("td");
        td.colSpan = tr.children.length;
        td.appendChild(buildExpenseTable(expenses, shipmentNo));
        detailRow.appendChild(td);

        tr.parentNode.insertBefore(detailRow, tr.nextSibling);
        tr.setAttribute("aria-expanded", "true");
    }

    function wireShipmentRows() {
        var rows = document.querySelectorAll("#icrShipmentBody tr.icr-ship-row");
        if (!window.CoreDrilldownModal) return;
        window.CoreDrilldownModal.wireClickableElements(rows, toggleShipmentRow);
    }

    /* ---------------- charts ---------------- */

    function renderStatusChart(shipments) {
        var el = $("icrStatusChart");
        if (!el) return;
        statusChart = statusChart || echarts.init(el);

        var colorMap = {
            "MATCHED": GOOD,
            "VARIANCE": CUT,
            "LOTS DIVERGE": TALLOW,
            "NO INVENTORY": TALLOW
        };
        var counts = {};
        shipments.forEach(function (s) {
            var key = s.ReconStatus || "UNKNOWN";
            counts[key] = (counts[key] || 0) + 1;
        });

        var data = Object.keys(counts).map(function (k) {
            return { name: k, value: counts[k], itemStyle: { color: colorMap[k] || STEEL } };
        });

        statusChart.setOption({
            tooltip: { trigger: "item" },
            legend: { bottom: 0, textStyle: { color: STEEL, fontSize: 11 } },
            series: [{
                type: "pie",
                radius: ["45%", "72%"],
                avoidLabelOverlap: true,
                label: { color: STEEL, fontSize: 11, formatter: "{b}: {c}" },
                data: data
            }]
        });
    }

    function renderTop10(shipments) {
        var el = $("icrTop10Chart");
        var listEl = $("icrTop10List");
        if (!el) return;
        top10Chart = top10Chart || echarts.init(el);

        var top10 = shipments.slice()
            .sort(function (a, b) { return Math.abs(b.VarianceValue) - Math.abs(a.VarianceValue); })
            .slice(0, 10);
        // Reverse so the biggest exposure renders at the top of the
        // horizontal bar (largest value nearest the axis origin's far end),
        // same convention as exec-dashboard.js's renderBranch/renderInventory.
        var chartData = top10.slice().reverse();

        top10Chart.setOption({
            grid: { left: 210, right: 60, top: 10, bottom: 24 },
            tooltip: {
                trigger: "axis",
                axisPointer: { type: "shadow" },
                formatter: function (params) {
                    var p = params[0];
                    var s = chartData[p.dataIndex];
                    return s.ShipmentNo + " · " + s.SupplierName + "<br/>" +
                        s.Status + " · " + s.BranchName + "<br/>" +
                        peso(s.VarianceValue);
                }
            },
            xAxis: {
                type: "value",
                axisLabel: { fontSize: 10, color: STEEL, formatter: function (v) { return peso(v); } },
                splitLine: { lineStyle: { color: LINE } }
            },
            yAxis: {
                type: "category",
                data: chartData.map(function (s) { return s.ShipmentNo + " · " + s.SupplierName; }),
                axisLabel: { fontSize: 10, color: STEEL },
                axisLine: { lineStyle: { color: LINE } }
            },
            series: [{
                type: "bar",
                // Uniform risk-red: this list ranks exposure magnitude, not
                // over- vs under-costing direction — it's explicitly the
                // "where to look first" list (handoff doc §5).
                data: chartData.map(function (s) { return { value: s.VarianceValue, itemStyle: { color: CUT } }; }),
                barMaxWidth: 18
            }]
        });

        if (listEl) {
            listEl.innerHTML =
                "<table><thead><tr>" +
                "<th>Shipment</th><th>Supplier</th><th>PO status</th><th>Branch</th>" +
                "<th class=\"n\" title=\"Variance value (received qty) — not a P&amp;L figure\">Variance value</th>" +
                "</tr></thead><tbody>" +
                top10.map(function (s) {
                    return "<tr>" +
                        "<td class=\"mono\">" + escHtml(s.ShipmentNo) + "</td>" +
                        "<td>" + escHtml(s.SupplierName) + "</td>" +
                        "<td>" + escHtml(s.Status) + "</td>" +
                        "<td>" + escHtml(s.BranchName) + "</td>" +
                        "<td class=\"n mono\">" + peso(s.VarianceValue) + "</td>" +
                        "</tr>";
                }).join("") +
                "</tbody></table>";
        }
    }

    // Variance value by supplier/branch — VARIANCE rows only, same scope as
    // the KPI tiles (handoff doc §5). Sorted ascending like exec-dashboard's
    // renderBranch so the largest positive value sits at the top of the bar.
    function aggregateVarianceByKey(shipments, key) {
        var totals = {};
        shipments.forEach(function (s) {
            if (s.ReconStatus !== "VARIANCE") return;
            var k = s[key] || "(unspecified)";
            totals[k] = (totals[k] || 0) + Number(s.VarianceValue);
        });
        return Object.keys(totals)
            .map(function (k) { return { name: k, value: totals[k] }; })
            .sort(function (a, b) { return a.value - b.value; });
    }

    function renderBarChart(elId, data) {
        var el = $(elId);
        if (!el) return null;
        var chart = echarts.init(el);

        chart.setOption({
            grid: { left: 160, right: 60, top: 10, bottom: 24 },
            tooltip: {
                trigger: "axis", axisPointer: { type: "shadow" },
                valueFormatter: function (v) { return peso(v); }
            },
            xAxis: {
                type: "value",
                axisLabel: { fontSize: 10, color: STEEL, formatter: function (v) { return peso(v); } },
                splitLine: { lineStyle: { color: LINE } }
            },
            yAxis: {
                type: "category",
                data: data.map(function (d) { return d.name; }),
                axisLabel: { fontSize: 10, color: STEEL },
                axisLine: { lineStyle: { color: LINE } }
            },
            series: [{
                type: "bar",
                // Sign, not just magnitude: positive (overstated) reads as
                // risk-red, negative (understated) as amber watch — both are
                // "wrong", but keeping direction visible is more useful than
                // a single uniform color for a group of several shipments.
                data: data.map(function (d) {
                    return { value: d.value, itemStyle: { color: d.value < 0 ? TALLOW : CUT } };
                }),
                barMaxWidth: 18
            }]
        });

        return chart;
    }

    /* ---------------- init ---------------- */

    document.addEventListener("DOMContentLoaded", function () {
        var shipments = window.CORE_SHIPMENTS || [];

        renderStatusChart(shipments);
        renderTop10(shipments);
        supplierChart = renderBarChart("icrSupplierChart", aggregateVarianceByKey(shipments, "SupplierName"));
        branchChart = renderBarChart("icrBranchChart", aggregateVarianceByKey(shipments, "BranchName"));

        if (window.CoreDrilldownModal) {
            modal = window.CoreDrilldownModal.create({
                veilId: "icrVeil",
                titleId: "icrTitle",
                subId: "icrSub",
                bodyId: "icrBody",
                closeBtnId: "icrCloseBtn",
                url: function (key) {
                    return "/ItemCostingRecon/TicketsDrilldown?referenceNumber=" + encodeURIComponent(key.referenceNumber) +
                        "&invoiceNo=" + encodeURIComponent(key.invoiceNo) +
                        "&shipmentNo=" + encodeURIComponent(key.shipmentNo);
                }
            });
            modal.wireCloseHandlers();
        }

        wireShipmentRows();
        wireFilters();

        window.addEventListener("resize", function () {
            [statusChart, top10Chart, supplierChart, branchChart].forEach(function (c) {
                if (c) c.resize();
            });
        });
    });
})();
