/* ============================================================================
   CORE REPORTING PORTAL — exec-dashboard.js
   Renders the two ECharts and drives the 5-minute polling refresh.
   Server data arrives on window.CORE_TREND and window.CORE_BRANCHES.
============================================================================ */
(function () {
    "use strict";

    var BRINE = "#3B82F6", CUT = "#F87171", STEEL = "#94A3B8",
        TALLOW = "#FBBF24", LINE = "#334155";

    var peso = function (v) {
        return "\u20B1" + Number(v).toLocaleString("en-PH",
            { minimumFractionDigits: 0, maximumFractionDigits: 0 });
    };
    var pesoM = function (v) { return "\u20B1" + (v / 1e6).toFixed(1) + "M"; };

    var trendChart, branchChart;

    function renderTrend(data) {
        var el = document.getElementById("trendChart");
        if (!el) return;
        trendChart = trendChart || echarts.init(el);

        trendChart.setOption({
            grid: { left: 56, right: 52, top: 24, bottom: 30 },
            tooltip: {
                trigger: "axis",
                valueFormatter: function (v) { return peso(v); }
            },
            legend: {
                data: ["Net sales", "COGS", "Margin %"],
                textStyle: { fontSize: 11, color: STEEL }, right: 0, top: 0
            },
            xAxis: {
                type: "category",
                data: data.map(function (d) { return d.MonthLabel; }),
                axisLine: { lineStyle: { color: LINE } },
                axisLabel: { fontSize: 10, color: STEEL }
            },
            yAxis: [
                {
                    type: "value",
                    axisLabel: {
                        fontSize: 10, color: STEEL,
                        formatter: function (v) { return pesoM(v); }
                    },
                    splitLine: { lineStyle: { color: LINE } }
                },
                {
                    type: "value", min: 0, max: 40, position: "right",
                    axisLabel: {
                        fontSize: 10, color: STEEL,
                        formatter: function (v) { return v + "%"; }
                    },
                    splitLine: { show: false }
                }
            ],
            series: [
                {
                    name: "Net sales", type: "bar",
                    data: data.map(function (d) { return d.NetSales; }),
                    itemStyle: { color: BRINE }, barMaxWidth: 26
                },
                {
                    name: "COGS", type: "bar",
                    data: data.map(function (d) { return d.Cogs; }),
                    itemStyle: { color: "#9FB4B7" }, barMaxWidth: 26
                },
                {
                    name: "Margin %", type: "line", yAxisIndex: 1, smooth: true,
                    data: data.map(function (d) {
                        return d.GrossMarginPct == null ? null
                            : Number(d.GrossMarginPct).toFixed(1);
                    }),
                    lineStyle: { color: TALLOW, width: 2 },
                    itemStyle: { color: TALLOW }
                }
            ]
        });
    }

    function renderBranch(data) {
        var el = document.getElementById("branchChart");
        if (!el) return;
        branchChart = branchChart || echarts.init(el);

        // Highest contribution at the top.
        var sorted = data.slice().sort(function (a, b) {
            return a.NetSales - b.NetSales;
        });

        branchChart.setOption({
            grid: { left: 120, right: 60, top: 10, bottom: 24 },
            tooltip: {
                trigger: "axis", axisPointer: { type: "shadow" },
                valueFormatter: function (v) { return peso(v); }
            },
            xAxis: {
                type: "value",
                axisLabel: {
                    fontSize: 10, color: STEEL,
                    formatter: function (v) { return pesoM(v); }
                },
                splitLine: { lineStyle: { color: LINE } }
            },
            yAxis: {
                type: "category",
                data: sorted.map(function (d) { return d.DisplayText; }),
                axisLabel: { fontSize: 10, color: STEEL },
                axisLine: { lineStyle: { color: LINE } }
            },
            series: [{
                type: "bar",
                data: sorted.map(function (d) { return d.NetSales; }),
                itemStyle: { color: BRINE, borderRadius: [0, 2, 2, 0] },
                barMaxWidth: 18
            }]
        });
    }

    function renderFlow(flow) {
        // Rebuild the flow bar from polled data without a page reload.
        var bar = document.getElementById("flowBar");
        if (!bar || !flow) return;
        bar.innerHTML = flow.sort(function (a, b) { return a.StageOrder - b.StageOrder; })
            .map(function (s) {
                if (s.IsAvailable && s.Amount != null) {
                    return '<div class="st"><div class="lbl">' + s.StageLabel +
                        '</div><div class="amt">' + pesoM(s.Amount) +
                        '</div><div class="cnt">from general ledger</div></div>';
                }
                return '<div class="st pending"><div class="lbl">' + s.StageLabel +
                    '</div><div class="amt pendingtext">\u2014</div>' +
                    '<div class="cnt">needs order tables</div></div>';
            }).join("");
    }

    function applyKpis(s) {
        var set = function (id, val) {
            var e = document.getElementById(id); if (e) e.textContent = val;
        };
        set("kpiNetSales", peso(s.NetSales));
        set("kpiMargin", (s.GrossMarginPct == null ? "\u2013"
            : Number(s.GrossMarginPct).toFixed(1)) + "%");
        set("kpiCash", peso(s.CashPosition));
        set("kpiAr", peso(s.ReceivablesTrade));
    }

    /* ---------- polling refresh ---------- */
    var POLL_MS = 5 * 60 * 1000;

    function refresh(force) {
        var btn = document.getElementById("refreshBtn");
        var flag = document.getElementById("freshFlag");
        if (force && btn) { btn.textContent = "Refreshing\u2026"; btn.disabled = true; }

        fetch("/Dashboard/ExecutiveData?force=" + (force ? "true" : "false"),
            { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (!r.ok) throw new Error("status " + r.status);
                return r.json();
            })
            .then(function (d) {
                applyKpis(d.summary);
                renderTrend(d.trend);
                renderBranch(d.branches);
                renderFlow(d.flow);
                var asOf = document.getElementById("asOf");
                if (asOf) asOf.textContent = d.generatedAt;
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

    /* ---------- init ---------- */
    document.addEventListener("DOMContentLoaded", function () {
        // First paint from the server-rendered payload.
        renderTrend(window.CORE_TREND || []);
        renderBranch(window.CORE_BRANCHES || []);

        var btn = document.getElementById("refreshBtn");
        if (btn) btn.addEventListener("click", function () { refresh(true); });

        // Mark data stale, then pull fresh figures, every 5 minutes.
        setInterval(function () {
            var flag = document.getElementById("freshFlag");
            if (flag) { flag.textContent = "checking\u2026"; }
            refresh(false);
        }, POLL_MS);

        window.addEventListener("resize", function () {
            if (trendChart) trendChart.resize();
            if (branchChart) branchChart.resize();
        });
    });
})();
