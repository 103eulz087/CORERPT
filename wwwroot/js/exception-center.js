/* ============================================================================
   CORE REPORTING PORTAL — exception-center.js
   Thin wrapper around the shared drilldown-modal.js (see health-check.js for
   the sibling wrapper): wires Exception Center's own modal markup/IDs
   (excVeil/excTitle/excSub/excBody/excCloseBtn) and its own endpoint
   (/ExceptionCenter/Detail?code=) to the generic modal + table renderer.

   Also owns the card-grid render (grouped by Category) and the 5-minute
   polling refresh, mirroring agent-scorecard.js's refresh()/freshFlag/asOf
   pattern exactly. The grid is fully server-rendered by Index.cshtml on
   first paint; refresh() rebuilds the same markup client-side from
   /ExceptionCenter/IndexData's JSON so a poll never has to reload the page,
   then re-wires click handlers (innerHTML replacement drops old listeners).
============================================================================ */
(function () {
    "use strict";

    function escapeHtml(s) {
        return window.CoreDrilldownModal ? window.CoreDrilldownModal.escapeHtml(s) : String(s == null ? "" : s);
    }

    // MVC's default camelCase JSON policy lowercases only the leading
    // capital here (no acronyms in this model, unlike AgentScorecard's
    // AR*/DSO fields), so a plain lowerFirst is safe and exact.
    function g(row, pascalKey) {
        if (!row) return undefined;
        if (row[pascalKey] !== undefined) return row[pascalKey];
        var camel = pascalKey.charAt(0).toLowerCase() + pascalKey.slice(1);
        return row[camel];
    }

    function peso(v) {
        // Never render an unavailable/zero-findings value-at-risk as ₱0.00 —
        // null means "no value to show", not zero. Same convention as
        // FlowStage.IsAvailable ("pending" instead of a fabricated zero).
        if (v === null || v === undefined) return "–";
        return "₱" + Number(v).toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }

    function pillClass(severity) {
        if (severity === "Critical") return "p-bad";
        if (severity === "Warning") return "p-warn";
        return "p-neu";
    }

    function cardHtml(row) {
        var code = g(row, "ExceptionCode");
        var title = g(row, "Title");
        var severity = g(row, "Severity");
        var findings = Number(g(row, "Findings") || 0);
        var valueAtRisk = g(row, "ValueAtRisk");
        var hasDrillDown = !!g(row, "HasDrillDown");
        var clickable = hasDrillDown && findings > 0;

        return "<div class=\"rcard" + (clickable ? "" : " exc-noclick") + "\"" +
            " data-code=\"" + escapeHtml(code) + "\"" +
            " data-title=\"" + escapeHtml(title) + "\"" +
            (clickable ? " tabindex=\"0\" role=\"button\" aria-label=\"View details for " + escapeHtml(title) + "\"" : "") +
            ">" +
            "<span class=\"pill " + pillClass(severity) + "\">" + escapeHtml(severity) + "</span>" +
            "<h3>" + escapeHtml(title) + "</h3>" +
            "<div class=\"exc-row\"><span>Findings</span><span class=\"mono\">" +
            findings.toLocaleString("en-PH") + "</span></div>" +
            "<div class=\"exc-row\"><span>Value at risk</span><span class=\"mono\">" +
            peso(valueAtRisk) + "</span></div>" +
            (clickable ? "<div class=\"exc-status\"><span class=\"hc-view-hint\">View details &rsaquo;</span></div>" : "") +
            "</div>";
    }

    function buildGridHtml(rows) {
        var categories = [];
        var byCategory = {};
        (rows || []).forEach(function (r) {
            var cat = g(r, "Category") || "";
            if (!byCategory[cat]) { byCategory[cat] = []; categories.push(cat); }
            byCategory[cat].push(r);
        });

        return categories.map(function (cat) {
            return "<div class=\"rc-group\">" +
                "<div class=\"eyebrow\" style=\"margin-bottom:8px;\">" + escapeHtml(cat) + "</div>" +
                "<div class=\"rc-cardgrid\">" +
                byCategory[cat].map(cardHtml).join("") +
                "</div></div>";
        }).join("");
    }

    function updateSummaryStrip(rows) {
        var strip = document.getElementById("excSummaryStrip");
        if (!strip) return;
        var criticals = (rows || []).filter(function (r) {
            return g(r, "Severity") === "Critical" && Number(g(r, "Findings") || 0) > 0;
        }).length;

        if (criticals === 0) {
            strip.className = "note-strip ok";
            strip.innerHTML = "<b>No critical exceptions.</b> Warning/Info findings, if any, are worth a look but do not require immediate action.";
        } else {
            strip.className = "note-strip bad";
            strip.innerHTML = "<b>" + criticals + " critical exception(s).</b> These indicate a control that was bypassed or a step that was skipped — review before period close.";
        }
    }

    function wireCards(modal) {
        var cards = document.querySelectorAll("#excGrid .rcard[data-code]:not(.exc-noclick)");
        window.CoreDrilldownModal.wireClickableElements(cards, function (card) {
            modal.open(card.getAttribute("data-code"), card.getAttribute("data-title"));
        });
    }

    /* ---------- polling refresh ---------- */
    var POLL_MS = 5 * 60 * 1000;

    function refresh(force, modal) {
        var btn = document.getElementById("refreshBtn");
        var flag = document.getElementById("freshFlag");
        if (force && btn) { btn.textContent = "Refreshing…"; btn.disabled = true; }

        fetch("/ExceptionCenter/IndexData?force=" + (force ? "true" : "false"),
            { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (!r.ok) throw new Error("status " + r.status);
                return r.json();
            })
            .then(function (d) {
                var rows = d.rows || d.Rows || [];
                var grid = document.getElementById("excGrid");
                if (grid) grid.innerHTML = buildGridHtml(rows);
                updateSummaryStrip(rows);
                wireCards(modal);

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
        if (!window.CoreDrilldownModal) return;

        var modal = window.CoreDrilldownModal.create({
            veilId: "excVeil",
            titleId: "excTitle",
            subId: "excSub",
            bodyId: "excBody",
            closeBtnId: "excCloseBtn",
            url: function (code) {
                return "/ExceptionCenter/Detail?code=" + encodeURIComponent(code);
            }
        });
        modal.wireCloseHandlers();
        wireCards(modal);

        var refreshBtn = document.getElementById("refreshBtn");
        if (refreshBtn) refreshBtn.addEventListener("click", function () { refresh(true, modal); });

        setInterval(function () {
            var flag = document.getElementById("freshFlag");
            if (flag) { flag.textContent = "checking…"; }
            refresh(false, modal);
        }, POLL_MS);
    });
})();
