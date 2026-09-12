/* ============================================================================
   CORE REPORTING PORTAL — accounting-dashboard.js
   Finance Overview: AR/AP aging charts + tables, 5-minute polling refresh.
   Mirrors exec-dashboard.js's refresh()/freshFlag/asOf pattern.

   Server data arrives two ways with two different casings, by design:
   - First paint: window.CORE_AR_* / CORE_AP_* are serialized directly with
     System.Text.Json.JsonSerializer (PascalCase, matches the C# model).
   - Poll refresh: FinanceOverviewData returns MVC's Json() result, which
     applies the app's default camelCase policy.
   g() below reads either casing so both paths work through the same
   render functions.
============================================================================ */
(function () {
    "use strict";

    var BRAND = "#3B82F6", WARN = "#FBBF24", RISK = "#F87171", MUTED = "#94A3B8", LINE = "#334155";

    function g(row, pascalKey) {
        if (!row) return undefined;
        if (row[pascalKey] !== undefined) return row[pascalKey];
        var camel = pascalKey.charAt(0).toLowerCase() + pascalKey.slice(1);
        return row[camel];
    }

    var peso = function (v) {
        return "₱" + Number(v || 0).toLocaleString("en-PH",
            { minimumFractionDigits: 0, maximumFractionDigits: 0 });
    };

    function findTotal(list, label) {
        label = label || "TOTAL";
        var found = (list || []).filter(function (r) { return g(r, "Label") === label; });
        return found[0] || {};
    }

    var arChart, apChart, apExpChart;

    function bucketSeries(total) {
        return [
            { value: g(total, "CurrentAmount") || 0, itemStyle: { color: BRAND } },
            { value: g(total, "PastDue1To30") || 0, itemStyle: { color: WARN } },
            { value: g(total, "PastDue31To60") || 0, itemStyle: { color: RISK, opacity: 0.55 } },
            { value: g(total, "PastDue61To90") || 0, itemStyle: { color: RISK, opacity: 0.78 } },
            { value: g(total, "PastDue90Plus") || 0, itemStyle: { color: RISK, opacity: 1 } }
        ];
    }

    function renderAgingChart(elId, total, existing) {
        var el = document.getElementById(elId);
        if (!el) return existing;
        var chart = existing || echarts.init(el);
        chart.setOption({
            grid: { left: 60, right: 20, top: 14, bottom: 26 },
            tooltip: { trigger: "axis", axisPointer: { type: "shadow" }, valueFormatter: function (v) { return peso(v); } },
            xAxis: {
                type: "category",
                data: ["Current", "1–30", "31–60", "61–90", "90+"],
                axisLine: { lineStyle: { color: LINE } },
                axisLabel: { fontSize: 10.5, color: MUTED }
            },
            yAxis: {
                type: "value",
                axisLabel: { fontSize: 10, color: MUTED, formatter: function (v) { return peso(v); } },
                splitLine: { lineStyle: { color: LINE } }
            },
            series: [{ type: "bar", data: bucketSeries(total), barMaxWidth: 46 }]
        });
        return chart;
    }

    function exposurePillClass(pct) {
        if (pct === null || pct === undefined) return "p-neu";
        if (pct > 100) return "p-bad";
        if (pct >= 85) return "p-warn";
        return "p-ok";
    }

    function renderCreditExposureTable(customers) {
        var tbody = document.querySelector("#creditExposureTable tbody");
        if (!tbody) return;
        var sorted = (customers || []).slice().sort(function (a, b) {
            var pa = g(a, "ExposurePct"), pb = g(b, "ExposurePct");
            return (pb === null || pb === undefined ? -1 : pb) - (pa === null || pa === undefined ? -1 : pa);
        });
        tbody.innerHTML = sorted.map(function (c) {
            var limit = g(c, "CreditLimit");
            var pct = g(c, "ExposurePct");
            var term = g(c, "Term");
            return "<tr>" +
                "<td>" + g(c, "CustomerName") + " <span class=\"mono\" style=\"color:var(--muted)\">(" + g(c, "CustomerKey") + ")</span></td>" +
                "<td class=\"mono\">" + g(c, "BranchCode") + "</td>" +
                "<td class=\"mono\">" + (term != null ? term + "d" : "–") + "</td>" +
                "<td class=\"n mono\">" + (limit != null ? peso(limit) : "–") + "</td>" +
                "<td class=\"n\">" + (pct != null
                    ? "<span class=\"pill " + exposurePillClass(pct) + "\">" + Number(pct).toFixed(1) + "%</span>"
                    : "<span class=\"mono\">—</span>") + "</td>" +
                "<td class=\"n mono\">" + g(c, "OldestAgeDays") + " d</td>" +
                "</tr>";
        }).join("");
    }

    function renderArCustomerTable(customers, total) {
        var tbody = document.querySelector("#arCustomerTable tbody");
        if (!tbody) return;
        var sorted = (customers || []).slice().sort(function (a, b) {
            return g(b, "TotalOutstanding") - g(a, "TotalOutstanding");
        });
        tbody.innerHTML = sorted.map(function (c) {
            return "<tr>" +
                "<td>" + g(c, "CustomerName") + " <span class=\"mono\" style=\"color:var(--muted)\">(" + g(c, "CustomerKey") + ")</span></td>" +
                "<td class=\"mono\">" + g(c, "BranchCode") + "</td>" +
                "<td class=\"n mono\">" + peso(g(c, "CurrentAmount")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(c, "PastDue1To30")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(c, "PastDue31To60")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(c, "PastDue61To90")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(c, "PastDue90Plus")) + "</td>" +
                "<td class=\"n mono\"><b>" + peso(g(c, "TotalOutstanding")) + "</b></td>" +
                "</tr>";
        }).join("");

        var tfoot = document.querySelector("#arCustomerTable tfoot");
        if (tfoot) {
            tfoot.innerHTML = "<tr><td colspan=\"2\">Total</td>" +
                "<td class=\"n mono\">" + peso(g(total, "CurrentAmount")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue1To30")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue31To60")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue61To90")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue90Plus")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "TotalOutstanding")) + "</td></tr>";
        }
    }

    function renderApSupplierTable(suppliers, total, tableId) {
        tableId = tableId || "apSupplierTable";
        var tbody = document.querySelector("#" + tableId + " tbody");
        if (!tbody) return;
        var sorted = (suppliers || []).slice().sort(function (a, b) {
            return g(b, "TotalOutstanding") - g(a, "TotalOutstanding");
        });
        tbody.innerHTML = sorted.map(function (s) {
            return "<tr>" +
                "<td>" + g(s, "SupplierName") + " <span class=\"mono\" style=\"color:var(--muted)\">(" + g(s, "SupplierId") + ")</span></td>" +
                "<td class=\"n mono\">" + peso(g(s, "CurrentAmount")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(s, "PastDue1To30")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(s, "PastDue31To60")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(s, "PastDue61To90")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(s, "PastDue90Plus")) + "</td>" +
                "<td class=\"n mono\"><b>" + peso(g(s, "TotalOutstanding")) + "</b></td>" +
                "<td class=\"n mono\">" + g(s, "OldestAgeDays") + " d</td>" +
                "</tr>";
        }).join("");

        var tfoot = document.querySelector("#" + tableId + " tfoot");
        if (tfoot) {
            tfoot.innerHTML = "<tr><td>Total</td>" +
                "<td class=\"n mono\">" + peso(g(total, "CurrentAmount")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue1To30")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue31To60")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue61To90")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "PastDue90Plus")) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "TotalOutstanding")) + "</td><td></td></tr>";
        }
    }

    function renderDailyActivity(branches, total) {
        var set = function (id, val) { var e = document.getElementById(id); if (e) e.textContent = val; };
        set("dailyActivityCount", g(total, "InvoiceCount") || 0);
        set("dailyActivityTotal", peso(g(total, "TotalAmount")));

        var tbody = document.querySelector("#dailyActivityTable tbody");
        if (tbody) {
            tbody.innerHTML = (branches || []).map(function (b) {
                return "<tr>" +
                    "<td class=\"mono\">" + g(b, "BranchCode") + "</td>" +
                    "<td>" + g(b, "BranchName") + "</td>" +
                    "<td class=\"n mono\">" + g(b, "InvoiceCount") + "</td>" +
                    "<td class=\"n mono\">" + peso(g(b, "TotalAmount")) + "</td>" +
                    "</tr>";
            }).join("");
        }

        var tfoot = document.querySelector("#dailyActivityTable tfoot");
        if (tfoot) {
            tfoot.innerHTML = "<tr><td colspan=\"2\">Total</td>" +
                "<td class=\"n mono\">" + (g(total, "InvoiceCount") || 0) + "</td>" +
                "<td class=\"n mono\">" + peso(g(total, "TotalAmount")) + "</td></tr>";
        }
    }

    function applyKpis(dso, arTotal) {
        var set = function (id, val) { var e = document.getElementById(id); if (e) e.textContent = val; };
        var pastDue = (g(arTotal, "PastDue31To60") || 0) + (g(arTotal, "PastDue61To90") || 0) + (g(arTotal, "PastDue90Plus") || 0);
        set("kpiArOutstanding", peso(g(arTotal, "TotalOutstanding")));
        set("kpiArPastDue", peso(pastDue));
        var dsoVal = g(dso, "Dso");
        set("kpiDso", dsoVal !== null && dsoVal !== undefined ? Number(dsoVal).toFixed(0) : "–");
    }

    /* ---------- polling refresh ---------- */
    var POLL_MS = 5 * 60 * 1000;

    function refresh(force) {
        var btn = document.getElementById("refreshBtn");
        var flag = document.getElementById("freshFlag");
        if (force && btn) { btn.textContent = "Refreshing…"; btn.disabled = true; }

        fetch("/Accounting/FinanceOverviewData?force=" + (force ? "true" : "false"),
            { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (!r.ok) throw new Error("status " + r.status);
                return r.json();
            })
            .then(function (d) {
                var arCustomers = d.arCustomers || d.ArCustomers || [];
                var arBranchTotals = d.arBranchTotals || d.ArBranchTotals || [];
                var arDso = d.arDso || d.ArDso || {};
                var apSuppliers = d.apSuppliers || d.ApSuppliers || [];
                var apCompanyTotal = d.apCompanyTotal || d.ApCompanyTotal || {};
                var apExpSuppliers = d.apExpSuppliers || d.ApExpSuppliers || [];
                var apExpCompanyTotal = d.apExpCompanyTotal || d.ApExpCompanyTotal || {};
                var dailyBranches = d.dailyBranches || d.DailyBranches || [];
                var dailyCompanyTotal = d.dailyCompanyTotal || d.DailyCompanyTotal || {};
                var arTotal = findTotal(arBranchTotals, "TOTAL");

                applyKpis(arDso, arTotal);
                arChart = renderAgingChart("arAgingChart", arTotal, arChart);
                apChart = renderAgingChart("apAgingChart", apCompanyTotal, apChart);
                apExpChart = renderAgingChart("apExpAgingChart", apExpCompanyTotal, apExpChart);
                renderCreditExposureTable(arCustomers);
                renderArCustomerTable(arCustomers, arTotal);
                renderApSupplierTable(apSuppliers, apCompanyTotal, "apSupplierTable");
                renderApSupplierTable(apExpSuppliers, apExpCompanyTotal, "apExpSupplierTable");
                renderDailyActivity(dailyBranches, dailyCompanyTotal);

                var asOf = document.getElementById("asOf");
                if (asOf) asOf.textContent = d.generatedAt || d.GeneratedAt;
                if (flag) { flag.textContent = "fresh"; flag.classList.remove("stale"); }
            })
            .catch(function (e) {
                if (flag) { flag.textContent = "stale"; flag.classList.add("stale"); }
                console.error("Refresh failed:", e);
            })
            .finally(function () {
                if (force && btn) { btn.textContent = "Refresh"; btn.disabled = false; }
            });
    }

    /* ---------- chart -> detail-table "Show details" toggle ----------
       Detail tables start hidden (server-rendered with style="display:none")
       so the page opens on the three charts, not a wall of rows; each
       chart's link reveals (and can re-hide) only its own table. */
    function wireDetailToggle(link) {
        var target = document.getElementById(link.getAttribute("data-toggle-details"));
        if (!target) return;
        var showText = link.textContent;
        var hideText = showText.replace(/^Show/, "Hide");
        link.addEventListener("click", function (e) {
            e.preventDefault();
            var opening = target.style.display === "none";
            target.style.display = opening ? "" : "none";
            link.textContent = opening ? hideText : showText;
        });
    }

    /* ---------- init ---------- */
    document.addEventListener("DOMContentLoaded", function () {
        var arCustomers = window.CORE_AR_CUSTOMERS || [];
        var arBranchTotals = window.CORE_AR_BRANCH_TOTALS || [];
        var arTotal = findTotal(arBranchTotals, "TOTAL");

        arChart = renderAgingChart("arAgingChart", arTotal, null);
        apChart = renderAgingChart("apAgingChart", window.CORE_AP_COMPANY_TOTAL || {}, null);
        apExpChart = renderAgingChart("apExpAgingChart", window.CORE_APEXP_COMPANY_TOTAL || {}, null);
        renderDailyActivity(window.CORE_DAILY_BRANCHES || [], window.CORE_DAILY_COMPANY_TOTAL || {});

        var btn = document.getElementById("refreshBtn");
        if (btn) btn.addEventListener("click", function () { refresh(true); });

        document.querySelectorAll("[data-toggle-details]").forEach(wireDetailToggle);

        setInterval(function () {
            var flag = document.getElementById("freshFlag");
            if (flag) { flag.textContent = "checking…"; }
            refresh(false);
        }, POLL_MS);

        window.addEventListener("resize", function () {
            if (arChart) arChart.resize();
            if (apChart) apChart.resize();
            if (apExpChart) apExpChart.resize();
        });
    });
})();
