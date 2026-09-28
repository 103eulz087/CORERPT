/* ============================================================================
   CORE REPORTING PORTAL — supplier-price.js

   Supplier Price Comparison (Views/SupplierPrice/Index.cshtml). No polling
   endpoint: Refresh is a server-rendered link with &force=true, so the only
   data shape is window.CORE_SPC, embedded as exact C# PascalCase.

   Drives:
   - the trend line chart (landed ₱/kg per period, top 6 suppliers by kg);
   - the whole-range ranking (stacked bar: supplier invoice + add-ons ₱/kg);
   - client-side period/supplier/product filters over the rendered tables;
   - shipment row -> linked-invoices sub-table (from CORE_SPC.expenses,
     already on the page, no extra fetch).

   Every ₱/kg shown here is the server's weighted figure. Nothing is
   averaged client-side: an average of per-period rates would not be a
   weighted rate.
============================================================================ */
(function () {
    "use strict";

    var STEEL = "#94A3B8", LINE = "#334155";
    // Series palette: neon blue / emerald / amber first (design system),
    // then three extra non-red hues. Risk red is never a series colour.
    var SERIES = ["#3B82F6", "#34D399", "#FBBF24", "#A78BFA", "#22D3EE", "#F472B6"];

    var trendChart, rankChart;

    function $(id) { return document.getElementById(id); }

    function esc(s) {
        return String(s == null ? "" : s)
            .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
    }

    function peso(v) {
        var n = Number(v) || 0;
        var f = "₱" + Math.abs(n).toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        return n < 0 ? "(" + f + ")" : f;
    }

    function perKg(v) {
        if (v === null || v === undefined) return "–";
        return "₱" + Number(v).toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + "/kg";
    }

    /* ---------------- trend: landed ₱/kg by supplier per period ---------------- */

    function renderTrend(data) {
        var el = $("spcTrendChart");
        if (!el) return;
        var rows = data.supplierPeriods || [];
        if (!rows.length) {
            el.innerHTML = "<div class=\"hc-empty\">No priced shipments in range.</div>";
            return;
        }

        // Periods oldest -> newest along the x axis.
        var periods = [];
        rows.slice().sort(function (a, b) { return a.PeriodStart < b.PeriodStart ? -1 : 1; })
            .forEach(function (r) { if (periods.indexOf(r.PeriodLabel) < 0) periods.push(r.PeriodLabel); });

        // Top 6 suppliers by received kg over the whole range.
        var kgBySupplier = {};
        rows.forEach(function (r) {
            kgBySupplier[r.SupplierId] = (kgBySupplier[r.SupplierId] || 0) + Number(r.ReceivedKg);
        });
        var top = Object.keys(kgBySupplier)
            .sort(function (a, b) { return kgBySupplier[b] - kgBySupplier[a]; })
            .slice(0, 6);

        var series = top.map(function (sid, i) {
            var name = "";
            var byPeriod = {};
            rows.forEach(function (r) {
                if (r.SupplierId !== sid) return;
                name = r.SupplierName;
                byPeriod[r.PeriodLabel] = r;
            });
            return {
                name: name,
                type: "line",
                connectNulls: false,
                symbolSize: 7,
                lineStyle: { width: 2 },
                itemStyle: { color: SERIES[i % SERIES.length] },
                data: periods.map(function (p) {
                    var r = byPeriod[p];
                    return r ? { value: Number(r.LandedCostPerKg), row: r } : null;
                })
            };
        });

        trendChart = trendChart || echarts.init(el);
        trendChart.setOption({
            grid: { left: 70, right: 20, top: 40, bottom: 40 },
            legend: { top: 0, textStyle: { color: STEEL, fontSize: 11 }, type: "scroll" },
            tooltip: {
                trigger: "axis",
                formatter: function (params) {
                    var out = params.length ? esc(params[0].axisValue) : "";
                    params.forEach(function (p) {
                        if (!p.data) return;
                        var r = p.data.row;
                        out += "<br/>" + p.marker + esc(p.seriesName) + ": <b>" + perKg(r.LandedCostPerKg) + "</b>" +
                            " · " + Number(r.ReceivedKg).toLocaleString("en-PH") + " kg" +
                            (r.MixedShipments > 0 ? " · " + r.MixedShipments + " mixed" : "");
                    });
                    return out;
                }
            },
            xAxis: {
                type: "category",
                data: periods,
                axisLabel: { fontSize: 10, color: STEEL },
                axisLine: { lineStyle: { color: LINE } }
            },
            yAxis: {
                type: "value",
                scale: true,
                axisLabel: { fontSize: 10, color: STEEL, formatter: function (v) { return "₱" + v.toLocaleString("en-PH"); } },
                splitLine: { lineStyle: { color: LINE } }
            },
            series: series
        });
    }

    /* ---------------- whole-range ranking: supplier invoice + add-ons ---------------- */

    function renderRank(data) {
        var el = $("spcRankChart");
        if (!el) return;
        // Cheapest first from the server; reverse so the cheapest is on top
        // of a horizontal bar chart.
        var rows = (data.supplierRange || []).slice(0, 12).reverse();
        if (!rows.length) {
            el.innerHTML = "<div class=\"hc-empty\">No priced shipments in range.</div>";
            return;
        }

        rankChart = rankChart || echarts.init(el);
        rankChart.setOption({
            grid: { left: 130, right: 20, top: 30, bottom: 24 },
            legend: { top: 0, textStyle: { color: STEEL, fontSize: 11 } },
            tooltip: {
                trigger: "axis",
                axisPointer: { type: "shadow" },
                formatter: function (params) {
                    var r = rows[params[0].dataIndex];
                    return esc(r.SupplierId + " - " + r.SupplierName) + "<br/>" +
                        "Supplier invoice: " + perKg(r.SupplierPricePerKg) + "<br/>" +
                        "Add-ons: " + perKg(r.AddOnPerKg) + "<br/>" +
                        "<b>Landed: " + perKg(r.LandedCostPerKg) + "</b><br/>" +
                        Number(r.ReceivedKg).toLocaleString("en-PH") + " kg · " + r.Shipments + " shipment" +
                        (r.Shipments === 1 ? "" : "s");
                }
            },
            xAxis: {
                type: "value",
                axisLabel: { fontSize: 10, color: STEEL, formatter: function (v) { return "₱" + v.toLocaleString("en-PH"); } },
                splitLine: { lineStyle: { color: LINE } }
            },
            yAxis: {
                type: "category",
                data: rows.map(function (r) { return r.SupplierName; }),
                axisLabel: { fontSize: 10, color: STEEL, width: 120, overflow: "truncate" },
                axisLine: { lineStyle: { color: LINE } }
            },
            series: [
                {
                    name: "Supplier invoice", type: "bar", stack: "kg", barMaxWidth: 16,
                    itemStyle: { color: SERIES[0] },
                    data: rows.map(function (r) { return Number(r.SupplierPricePerKg); })
                },
                {
                    name: "Add-ons", type: "bar", stack: "kg", barMaxWidth: 16,
                    itemStyle: { color: SERIES[2] },
                    data: rows.map(function (r) { return Number(r.AddOnPerKg); })
                }
            ]
        });
    }

    /* ---------------- client-side table filters ---------------- */

    function wireFilter(selectIds, rowSelector, attrs) {
        function apply() {
            var vals = selectIds.map(function (id) { return $(id) ? $(id).value : ""; });
            document.querySelectorAll(rowSelector).forEach(function (tr) {
                var ok = vals.every(function (v, i) { return !v || tr.getAttribute(attrs[i]) === v; });
                tr.style.display = ok ? "" : "none";
            });
        }
        selectIds.forEach(function (id) { if ($(id)) $(id).addEventListener("change", apply); });
    }

    /* ---------------- shipment -> linked invoices ---------------- */

    function invoiceTable(expenses) {
        if (!expenses.length) return "<div class=\"hc-empty\">No linked invoices.</div>";
        return "<div class=\"icr-subtable-wrap\"><table><thead><tr>" +
            "<th>Cost role</th><th>Reference</th><th>Invoice no.</th><th>Invoiced by</th><th>Date</th>" +
            "<th>Description</th><th>Status</th><th class=\"n\">Amount</th>" +
            "</tr></thead><tbody>" +
            expenses.map(function (e) {
                var role = e.CostRole === "SUPPLIER"
                    ? "<span class=\"pill p-ok\">SUPPLIER</span>"
                    : "<span class=\"pill p-neu\">ADD-ON</span>";
                return "<tr>" +
                    "<td>" + role + "</td>" +
                    "<td class=\"mono\">" + esc(e.ReferenceNumber) + "</td>" +
                    "<td class=\"mono\">" + esc(e.InvoiceNo) + "</td>" +
                    "<td>" + esc(e.ExpenseSupplierId + " - " + e.ExpenseSupplierName) + "</td>" +
                    "<td class=\"mono\">" + esc(e.ExpenseDate ? String(e.ExpenseDate).slice(0, 10) : "–") + "</td>" +
                    "<td>" + esc(e.Description) + "</td>" +
                    "<td>" + esc(e.ExpenseStatus) + (e.IsPostedToGl ? "" : " <span class=\"pill p-warn\">not posted</span>") + "</td>" +
                    "<td class=\"n mono\">" + peso(e.Amount) + "</td>" +
                    "</tr>";
            }).join("") +
            "</tbody></table></div>";
    }

    function toggleShipment(tr, expenses) {
        var next = tr.nextElementSibling;
        if (next && next.classList.contains("spc-invoice-row")) {
            next.parentNode.removeChild(next);
            tr.setAttribute("aria-expanded", "false");
            return;
        }
        var shipmentNo = tr.getAttribute("data-shipment");
        var detail = document.createElement("tr");
        detail.className = "spc-invoice-row";
        var td = document.createElement("td");
        td.colSpan = tr.children.length;
        td.innerHTML = invoiceTable(expenses.filter(function (e) { return e.ShipmentNo === shipmentNo; }));
        detail.appendChild(td);
        tr.parentNode.insertBefore(detail, tr.nextSibling);
        tr.setAttribute("aria-expanded", "true");
    }

    function wireShipments(expenses) {
        document.querySelectorAll("#spcShipmentBody tr.spc-ship-row").forEach(function (tr) {
            tr.addEventListener("click", function () { toggleShipment(tr, expenses); });
            tr.addEventListener("keydown", function (ev) {
                if (ev.key === "Enter" || ev.key === " ") {
                    ev.preventDefault();
                    toggleShipment(tr, expenses);
                }
            });
        });
    }

    /* ---------------- init ---------------- */

    document.addEventListener("DOMContentLoaded", function () {
        var data = window.CORE_SPC || {};

        renderTrend(data);
        renderRank(data);

        wireFilter(["spcFilterPeriod", "spcFilterSupplier"], "#spcSupplierBody tr.spc-sp-row",
            ["data-period", "data-supplier"]);
        wireFilter(["spcFilterProduct"], "#spcProductBody tr.spc-pp-row", ["data-product"]);
        wireShipments(data.expenses || []);

        window.addEventListener("resize", function () {
            [trendChart, rankChart].forEach(function (c) { if (c) c.resize(); });
        });
    });
})();
