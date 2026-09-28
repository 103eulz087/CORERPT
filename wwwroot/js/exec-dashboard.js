/* ============================================================================
   CORE REPORTING PORTAL — exec-dashboard.js
   Renders the ECharts and drives the 5-minute polling refresh. Server data
   arrives TWO ways with two different casings, by design:
   - First paint: window.CORE_TREND/CORE_BRANCHES/CORE_INVENTORY, embedded via
     Html.Raw(JsonSerializer.Serialize(...)) with no naming policy, so it
     keeps exact C# PascalCase (NetSales, DisplayText, ...).
   - Poll refresh: /Dashboard/ExecutiveData returns MVC's Json() result,
     which camelCases by default (netSales, displayText, ...) — confirmed
     against the live endpoint, not assumed.
   g() below reads either casing. Every field this file touches (ExecSummary,
   SalesTrendPoint, BranchScorecardRow, FlowStage, BranchInventoryRow) has at
   most ONE leading capital, never a multi-letter acronym run, so the simple
   lowercase-first-letter fallback is genuinely correct for all of them. That
   would NOT be safe to reuse verbatim on a DTO with an acronym-leading
   property (e.g. AROutstanding, whose real camelCase is arOutstanding, not
   aROutstanding) — see agent-scorecard.js's explicit CAMEL_KEYS map for that
   case.
============================================================================ */
(function () {
    "use strict";

    var BRINE = "#3B82F6", CUT = "#F87171", STEEL = "#94A3B8",
        TALLOW = "#FBBF24", LINE = "#334155";

    function g(row, pascalKey) {
        if (!row) return undefined;
        if (row[pascalKey] !== undefined) return row[pascalKey];
        var camel = pascalKey.charAt(0).toLowerCase() + pascalKey.slice(1);
        return row[camel];
    }

    var peso = function (v) {
        return "₱" + Number(v).toLocaleString("en-PH",
            { minimumFractionDigits: 0, maximumFractionDigits: 0 });
    };
    var pesoM = function (v) { return "₱" + (v / 1e6).toFixed(1) + "M"; };

    var trendChart, branchChart, inventoryChart;

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
                data: data.map(function (d) { return g(d, "MonthLabel"); }),
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
                    data: data.map(function (d) { return g(d, "NetSales"); }),
                    itemStyle: { color: BRINE }, barMaxWidth: 26
                },
                {
                    name: "COGS", type: "bar",
                    data: data.map(function (d) { return g(d, "Cogs"); }),
                    itemStyle: { color: "#9FB4B7" }, barMaxWidth: 26
                },
                {
                    name: "Margin %", type: "line", yAxisIndex: 1, smooth: true,
                    data: data.map(function (d) {
                        var pct = g(d, "GrossMarginPct");
                        return pct == null ? null : Number(pct).toFixed(1);
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
            return g(a, "NetSales") - g(b, "NetSales");
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
                data: sorted.map(function (d) { return g(d, "DisplayText"); }),
                axisLabel: { fontSize: 10, color: STEEL },
                axisLine: { lineStyle: { color: LINE } }
            },
            series: [{
                type: "bar",
                data: sorted.map(function (d) { return g(d, "NetSales"); }),
                itemStyle: { color: BRINE, borderRadius: [0, 2, 2, 0] },
                barMaxWidth: 18
            }]
        });
    }

    function renderInventory(data) {
        var el = document.getElementById("inventoryChart");
        var statsEl = document.getElementById("invStats");
        var gapNote = document.getElementById("invCostGapNote");
        if (!el) return;
        inventoryChart = inventoryChart || echarts.init(el);

        if (!data || !data.length) {
            inventoryChart.clear();
            if (statsEl) statsEl.innerHTML = "";
            if (gapNote) gapNote.style.display = "none";
            return;
        }

        // Highest on-hand value at the top, same convention as renderBranch.
        var sorted = data.slice().sort(function (a, b) {
            return g(a, "OnHandValue") - g(b, "OnHandValue");
        });

        inventoryChart.setOption({
            grid: { left: 150, right: 60, top: 10, bottom: 24 },
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
                data: sorted.map(function (d) { return g(d, "DisplayText"); }),
                axisLabel: { fontSize: 10, color: STEEL },
                axisLine: { lineStyle: { color: LINE } }
            },
            series: [{
                type: "bar",
                data: sorted.map(function (d) { return g(d, "OnHandValue"); }),
                itemStyle: { color: BRINE, borderRadius: [0, 2, 2, 0] },
                barMaxWidth: 18
            }]
        });

        // Highest/lowest callout by on-hand value — the executive's explicit
        // ask, not just a chart. Plain stat text, no risk color: a branch
        // carrying less stock than another isn't inherently a "risk".
        if (statsEl) {
            var highest = sorted[sorted.length - 1];
            var lowest = sorted[0];
            statsEl.innerHTML =
                '<span>Highest: <b class="mono">' + g(highest, "DisplayText") +
                '</b> <span class="mono">' + peso(g(highest, "OnHandValue")) + '</span></span>' +
                '<span style="margin-left:24px">Lowest: <b class="mono">' + g(lowest, "DisplayText") +
                '</b> <span class="mono">' + peso(g(lowest, "OnHandValue")) + '</span></span>';
        }

        // Cost-gap disclosure: OnHandValue is understated wherever cost wasn't
        // captured (see BranchInventoryRow.ZeroCostQuantityPct). Only surfaced
        // when it's actually material, not as a blanket disclaimer.
        if (gapNote) {
            var flagged = data.filter(function (d) {
                var pct = g(d, "ZeroCostQuantityPct");
                return pct != null && Number(pct) > 1;
            });
            if (flagged.length) {
                gapNote.style.display = "";
                gapNote.textContent = "On-hand value is understated for " +
                    flagged.map(function (d) {
                        return g(d, "DisplayText") + " (" +
                            Number(g(d, "ZeroCostQuantityPct")).toFixed(1) +
                            "% of quantity has no recorded cost)";
                    }).join(", ") + ".";
            } else {
                gapNote.style.display = "none";
            }
        }
    }

    function renderFlow(flow) {
        // Rebuild the flow bar from polled data without a page reload.
        var bar = document.getElementById("flowBar");
        if (!bar || !flow) return;
        bar.innerHTML = flow.sort(function (a, b) {
            return g(a, "StageOrder") - g(b, "StageOrder");
        })
            .map(function (s) {
                var amt = g(s, "Amount");
                if (g(s, "IsAvailable") && amt != null) {
                    return '<div class="st"><div class="lbl">' + g(s, "StageLabel") +
                        '</div><div class="amt">' + pesoM(amt) +
                        '</div><div class="cnt">from general ledger</div></div>';
                }
                return '<div class="st pending"><div class="lbl">' + g(s, "StageLabel") +
                    '</div><div class="amt pendingtext">—</div>' +
                    '<div class="cnt">needs order tables</div></div>';
            }).join("");
    }

    function escapeHtml(s) {
        return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c];
        });
    }

    /* Cash & bank position card is fully server-rendered on first paint
       (Views/Dashboard/Executive.cshtml) — this only needs to run on the
       5-minute poll refresh. Aggregated by AccountCode (summed across
       branches) same as the Razor first-paint markup: the per-branch split
       sp_rpt_Exec_CashPosition returns is remittance-attribution detail, not
       "which branch owns this account" (see CashPositionRow's doc comment),
       so it would just be table noise here. Negative balances get the
       amber .cash-neg class, never risk-red — see sql/25's header, a known
       missing-opening-balance artifact, not a real overdraft. */
    function renderCash(rows) {
        var heroEl = document.getElementById("cashHeroTotal");
        var inBankEl = document.getElementById("cashInBank");
        var onHandEl = document.getElementById("cashOnHand");
        var bodyEl = document.getElementById("cashTableBody");
        if (!heroEl || !bodyEl) return;

        rows = rows || [];
        var total = 0, inBank = 0, onHand = 0;
        var byAccount = {};

        rows.forEach(function (r) {
            var bal = Number(g(r, "Balance")) || 0;
            var cls = g(r, "Classification");
            total += bal;
            if (cls === "Cash in Bank") inBank += bal;
            else if (cls === "Cash on Hand") onHand += bal;

            var code = g(r, "AccountCode");
            if (!byAccount[code]) byAccount[code] = { name: g(r, "AccountName"), balance: 0 };
            byAccount[code].balance += bal;
        });

        heroEl.textContent = peso(total);
        if (inBankEl) inBankEl.textContent = peso(inBank);
        if (onHandEl) onHandEl.textContent = peso(onHand);

        var list = Object.keys(byAccount).map(function (k) { return byAccount[k]; })
            .sort(function (a, b) { return b.balance - a.balance; });

        if (!list.length) {
            bodyEl.innerHTML = '<tr><td colspan="2" class="hc-empty-row">No posted cash/bank activity for this period.</td></tr>';
            return;
        }

        bodyEl.innerHTML = list.map(function (a) {
            var isNeg = a.balance < 0;
            var isFx = a.name.indexOf("USD") !== -1 || a.name.indexOf("EURO") !== -1;
            var badge = isFx
                ? ' <span class="cash-fx-badge" title="This ERP does not track foreign currency separately — shown in PHP, not the account’s named currency.">PHP</span>'
                : '';
            return '<tr><td>' + escapeHtml(a.name) + badge + '</td>' +
                '<td class="n mono' + (isNeg ? ' cash-neg' : '') + '">' + peso(a.balance) + '</td></tr>';
        }).join("");
    }

    function applyKpis(s) {
        var set = function (id, val) {
            var e = document.getElementById(id); if (e) e.textContent = val;
        };
        var margin = g(s, "GrossMarginPct");
        set("kpiNetSales", peso(g(s, "NetSales")));
        set("kpiMargin", (margin == null ? "–" : Number(margin).toFixed(1)) + "%");
        set("kpiCash", peso(g(s, "CashPosition")));
        set("kpiAr", peso(g(s, "ReceivablesTrade")));
    }

    /* ---------- polling refresh ---------- */
    var POLL_MS = 5 * 60 * 1000;

    function refresh(force) {
        var btn = document.getElementById("refreshBtn");
        var flag = document.getElementById("freshFlag");
        if (force && btn) { btn.textContent = "Refreshing…"; btn.disabled = true; }

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
                renderInventory(d.inventoryByBranch);
                renderCash(d.cashPosition);
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

    /* "Show details" toggle — same convention as FinanceOverview's
       data-toggle-details links (see accounting-dashboard.js), duplicated
       here rather than shared since each dashboard page owns its own
       script file in this codebase. */
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
        // First paint from the server-rendered payload.
        renderTrend(window.CORE_TREND || []);
        renderBranch(window.CORE_BRANCHES || []);
        renderInventory(window.CORE_INVENTORY || []);

        document.querySelectorAll("[data-toggle-details]").forEach(wireDetailToggle);

        var btn = document.getElementById("refreshBtn");
        if (btn) btn.addEventListener("click", function () { refresh(true); });

        // Mark data stale, then pull fresh figures, every 5 minutes.
        setInterval(function () {
            var flag = document.getElementById("freshFlag");
            if (flag) { flag.textContent = "checking…"; }
            refresh(false);
        }, POLL_MS);

        window.addEventListener("resize", function () {
            if (trendChart) trendChart.resize();
            if (branchChart) branchChart.resize();
            if (inventoryChart) inventoryChart.resize();
        });
    });
})();
