/* ============================================================================
   CORE REPORTING PORTAL — agent-scorecard.js
   Sales > Agent Scorecard: leaderboard sort toggle + 5-minute polling refresh.
   Mirrors accounting-dashboard.js's refresh()/freshFlag/asOf pattern exactly.

   Server data arrives two ways with two different casings, by design:
   - First paint: the table is fully server-rendered by AgentScorecard.cshtml
     (Razor), so this file does nothing on load except wire up the sort
     buttons and the poll timer.
   - Poll refresh: AgentScorecardData returns MVC's Json() result, which
     applies the app's default camelCase policy. g() below reads either
     casing so the same render function would work for both, matching the
     accounting-dashboard.js convention even though only the poll path uses it.
============================================================================ */
(function () {
    "use strict";

    // AR-past-due-% risk cutoff — placeholder pending the developer's real
    // house number (see the matching comment in AgentScorecard.cshtml).
    var RISK_THRESHOLD_PCT = window.CORE_AGENT_RISK_THRESHOLD_PCT || 25;

    var currentSort = "netSales"; // or "arPastDue"

    // .NET's real JsonNamingPolicy.CamelCase lowercases an entire leading run
    // of capitals (AROutstanding -> arOutstanding, DSO -> dso), not just the
    // first character. A naive charAt(0).toLowerCase() guess gets every
    // single-capital property right by coincidence (NetSales, AgentLabel...)
    // but silently produces the wrong key for AR*/DSO — which then reads as
    // `undefined` on every poll refresh, coerces to 0 via peso(v||0), and
    // makes real AR exposure disappear after the first render. Map the exact
    // keys explicitly instead of re-deriving them.
    var CAMEL_KEYS = {
        AgentLabel: "agentLabel",
        RowType: "rowType",
        NetSales: "netSales",
        NetSalesPrior: "netSalesPrior",
        NetSalesDeltaPct: "netSalesDeltaPct",
        TotalAssignedAccounts: "totalAssignedAccounts",
        ActiveAccounts: "activeAccounts",
        DormantAccounts: "dormantAccounts",
        NewAccounts: "newAccounts",
        AROutstanding: "arOutstanding",
        ARPastDue31Plus: "arPastDue31Plus",
        ARPastDuePct: "arPastDuePct",
        OldestOpenItemAgeDays: "oldestOpenItemAgeDays",
        NetSales90Day: "netSales90Day",
        DSO: "dso"
    };

    function g(row, pascalKey) {
        if (!row) return undefined;
        if (row[pascalKey] !== undefined) return row[pascalKey];
        var camel = CAMEL_KEYS[pascalKey] || (pascalKey.charAt(0).toLowerCase() + pascalKey.slice(1));
        return row[camel];
    }

    var peso = function (v) {
        return "₱" + Number(v || 0).toLocaleString("en-PH",
            { minimumFractionDigits: 0, maximumFractionDigits: 0 });
    };

    // Same up/down-by-whether-it's-good convention as Executive.cshtml's
    // DeltaClass/DeltaText. Net sales is always higher-is-better.
    function deltaClass(pct) {
        if (pct === null || pct === undefined || Number(pct) === 0) return "flat";
        return Number(pct) > 0 ? "up" : "down";
    }

    function deltaText(pct) {
        if (pct === null || pct === undefined) return "–";
        var n = Number(pct);
        return (n > 0 ? "+" : "") + n.toFixed(1) + "%";
    }

    function rowHtml(row) {
        var type = g(row, "RowType") || "AGENT";
        var rowClass = type === "TOTAL" ? "row-total" : type === "UNASSIGNED" ? "row-unassigned" : "row-agent";
        var netSales = g(row, "NetSales") || 0;
        var deltaPct = g(row, "NetSalesDeltaPct");
        var arPct = g(row, "ARPastDuePct");
        var oldest = g(row, "OldestOpenItemAgeDays");
        var dso = g(row, "DSO");
        var dormant = g(row, "DormantAccounts") || 0;
        var label = g(row, "AgentLabel") || "";

        var nameHtml = type === "UNASSIGNED"
            ? "<span class=\"agent-name unassigned\">" + label + "</span>"
            : "<span class=\"agent-name\">" + label + "</span>";

        var arPctHtml;
        if (arPct === null || arPct === undefined) {
            arPctHtml = "<span class=\"mono\">–</span>";
        } else {
            var isRisk = Number(arPct) >= RISK_THRESHOLD_PCT;
            arPctHtml = "<span class=\"mono" + (isRisk ? " pill p-bad" : "") + "\">" +
                Number(arPct).toFixed(1) + "%</span>";
        }

        return "<tr class=\"" + rowClass + "\" data-row-type=\"" + type + "\"" +
            " data-net-sales=\"" + netSales + "\"" +
            " data-ar-pct=\"" + (arPct === null || arPct === undefined ? "" : arPct) + "\">" +
            "<td>" + nameHtml + " <span class=\"pill p-warn\">" + dormant + " dormant</span></td>" +
            "<td class=\"n mono\">" + peso(netSales) + "</td>" +
            "<td class=\"n\"><span class=\"delta " + deltaClass(deltaPct) + "\">" + deltaText(deltaPct) + "</span></td>" +
            "<td class=\"n mono\">" + (g(row, "TotalAssignedAccounts") || 0) + "</td>" +
            "<td class=\"n mono\">" + (g(row, "ActiveAccounts") || 0) + "</td>" +
            "<td class=\"n mono\">" + (g(row, "NewAccounts") || 0) + "</td>" +
            "<td class=\"n mono\">" + peso(g(row, "AROutstanding")) + "</td>" +
            "<td class=\"n mono\">" + peso(g(row, "ARPastDue31Plus")) + "</td>" +
            "<td class=\"n\">" + arPctHtml + "</td>" +
            "<td class=\"n mono\">" + (oldest === null || oldest === undefined ? "–" : oldest + " d") + "</td>" +
            "<td class=\"n mono\">" + (dso === null || dso === undefined ? "–" : Number(dso).toFixed(1)) + "</td>" +
            "</tr>";
    }

    // Client-side sort of the AGENT rows only. TOTAL and UNASSIGNED never
    // participate — TOTAL always stays last, UNASSIGNED just ahead of it.
    function sortAgentList(list) {
        list.sort(function (a, b) {
            var av, bv;
            if (currentSort === "arPastDue") {
                av = g(a, "ARPastDuePct");
                bv = g(b, "ARPastDuePct");
            } else {
                av = g(a, "NetSales");
                bv = g(b, "NetSales");
            }
            av = (av === null || av === undefined) ? -Infinity : Number(av);
            bv = (bv === null || bv === undefined) ? -Infinity : Number(bv);
            return bv - av;
        });
    }

    function renderTable(rows) {
        var tbody = document.querySelector("#agentScorecardTable tbody");
        if (!tbody) return;

        var agents = [], unassigned = null, total = null;
        (rows || []).forEach(function (r) {
            var t = g(r, "RowType");
            if (t === "TOTAL") total = r;
            else if (t === "UNASSIGNED") unassigned = r;
            else agents.push(r);
        });

        sortAgentList(agents);

        var html = agents.map(rowHtml).join("");
        if (unassigned) html += rowHtml(unassigned);
        if (total) html += rowHtml(total);
        tbody.innerHTML = html;
    }

    // Re-sort the already-rendered DOM rows in place (used by the sort
    // toggle buttons — no server round-trip). TOTAL/UNASSIGNED stay anchored
    // at the bottom in their existing fixed position.
    function sortDomRows() {
        var tbody = document.querySelector("#agentScorecardTable tbody");
        if (!tbody) return;

        var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr[data-row-type="AGENT"]'));
        var anchor = tbody.querySelector('tr[data-row-type="UNASSIGNED"]') ||
            tbody.querySelector('tr[data-row-type="TOTAL"]') || null;

        rows.sort(function (a, b) {
            var av, bv;
            if (currentSort === "arPastDue") {
                av = parseFloat(a.getAttribute("data-ar-pct"));
                bv = parseFloat(b.getAttribute("data-ar-pct"));
            } else {
                av = parseFloat(a.getAttribute("data-net-sales"));
                bv = parseFloat(b.getAttribute("data-net-sales"));
            }
            av = isNaN(av) ? -Infinity : av;
            bv = isNaN(bv) ? -Infinity : bv;
            return bv - av;
        });

        rows.forEach(function (r) { tbody.insertBefore(r, anchor); });
    }

    function setActiveButton(mode) {
        var byNetSales = document.getElementById("sortByNetSales");
        var byArPastDue = document.getElementById("sortByArPastDue");
        if (!byNetSales || !byArPastDue) return;
        if (mode === "arPastDue") {
            byNetSales.classList.add("ghost");
            byArPastDue.classList.remove("ghost");
        } else {
            byArPastDue.classList.add("ghost");
            byNetSales.classList.remove("ghost");
        }
    }

    /* ---------- polling refresh ---------- */
    var POLL_MS = 5 * 60 * 1000;

    function refresh(force) {
        var btn = document.getElementById("refreshBtn");
        var flag = document.getElementById("freshFlag");
        if (force && btn) { btn.textContent = "Refreshing…"; btn.disabled = true; }

        fetch("/Sales/AgentScorecardData?force=" + (force ? "true" : "false"),
            { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (!r.ok) throw new Error("status " + r.status);
                return r.json();
            })
            .then(function (d) {
                var rows = d.rows || d.Rows || [];
                renderTable(rows);

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

    /* ---------- init ---------- */
    document.addEventListener("DOMContentLoaded", function () {
        var byNetSales = document.getElementById("sortByNetSales");
        var byArPastDue = document.getElementById("sortByArPastDue");

        if (byNetSales) {
            byNetSales.addEventListener("click", function () {
                currentSort = "netSales";
                setActiveButton(currentSort);
                sortDomRows();
            });
        }
        if (byArPastDue) {
            byArPastDue.addEventListener("click", function () {
                currentSort = "arPastDue";
                setActiveButton(currentSort);
                sortDomRows();
            });
        }

        var refreshBtn = document.getElementById("refreshBtn");
        if (refreshBtn) refreshBtn.addEventListener("click", function () { refresh(true); });

        setInterval(function () {
            var flag = document.getElementById("freshFlag");
            if (flag) { flag.textContent = "checking…"; }
            refresh(false);
        }, POLL_MS);
    });
})();
