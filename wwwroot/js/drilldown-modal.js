/* ============================================================================
   CORE REPORTING PORTAL — drilldown-modal.js

   Shared, generic drill-down modal + column/row table renderer. Extracted out
   of health-check.js so a second consumer (Exception Center, and whatever
   comes after it) can reuse the exact same rendering behavior against a
   different data source/endpoint, instead of the ~90 lines of table-building
   logic being copy-pasted and drifting apart over time.

   Every consumer still owns its own modal markup/IDs (Health Check keeps
   hcVeil/hcTitle/hcSub/hcBody/hcCloseBtn unchanged) and its own endpoint —
   this module is parameterized via CoreDrilldownModal.create(config), not
   hardcoded to either caller.

   Consumes the generic { procName, renderStyle, generatedAt, resultSets:
   [{ columns, rows, totalRowCount }] } shape that DashboardController.
   HealthCheckDetail, ExceptionCenterController.Detail and
   ReportCenterController.RunReport all return. Most checks return exactly
   one result set — rendered as a single grid. The AR/AP subledger-vs-GL
   tie-outs (Health Check #12/#13) return three: the authoritative
   reconciliation, the check's own blind spots, and a capped list of
   candidate contributors whose Note text explicitly warns against treating
   them as proof — that Note is rendered in full, never truncated. This
   three-result-set special case is preserved exactly.

   totalRowCount (nullable) is the TRUE pre-cap row count when a proc emits
   it (see GetExceptionCenterDetailAsync's "TotalMatchCount" sentinel column
   — added 2026-09-26 after SALES-CREDIT-LIMIT-BREACH's real row count on
   production-scale data, 3,218, silently exceeded the proc's TOP(500) cap
   and the drilldown showed a partial sum with no indication it was
   partial). When present and greater than rows.length, appendSection shows
   a visible "showing top N of M" notice instead of a silent truncation.
   Null (the default for any result set whose SQL doesn't emit the sentinel,
   e.g. every Health Check check today) means rows.length already IS the
   true count — no notice, no behavior change from before this existed.
============================================================================ */
(function (global) {
    "use strict";

    function $(id) { return document.getElementById(id); }

    /* ---------------- formatting helpers (mirrors report-center.js) ---------------- */

    function escapeHtml(s) {
        return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c];
        });
    }

    function fmtNum(v) {
        if (v === null || v === undefined) return "–";
        var n = Number(v);
        if (Number.isNaN(n)) return escapeHtml(v);
        if (Number.isInteger(n)) return n.toLocaleString("en-PH");
        return n.toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }

    function fmtDate(v) {
        if (!v) return "–";
        return String(v).slice(0, 10);
    }

    function normName(name) {
        return String(name || "").replace(/[^a-z0-9]/gi, "").toLowerCase();
    }

    function colIndex(columns, wanted) {
        var target = normName(wanted);
        for (var i = 0; i < columns.length; i++) {
            if (normName(columns[i].name) === target) return i;
        }
        return -1;
    }

    /* ---------------- table builder ---------------- */

    function buildTable(rs) {
        var noteIdx = colIndex(rs.columns, "Note");

        var thead = "<thead><tr>" + rs.columns.map(function (c) {
            var n = c.type === "Number";
            return "<th class=\"" + (n ? "n" : "") + "\">" + escapeHtml(c.name) + "</th>";
        }).join("") + "</tr></thead>";

        var tbody;
        if (!rs.rows.length) {
            tbody = "<tbody><tr><td class=\"hc-empty-row\" colspan=\"" + rs.columns.length +
                "\">No rows.</td></tr></tbody>";
        } else {
            tbody = "<tbody>" + rs.rows.map(function (row) {
                return "<tr>" + row.map(function (v, i) {
                    var col = rs.columns[i];
                    var cls = [];
                    if (col.type === "Number") cls.push("n", "mono");
                    if (col.type === "Date") cls.push("mono");
                    if (i === noteIdx) cls.push("hc-note-cell");

                    var text;
                    if (col.type === "Number") text = fmtNum(v);
                    else if (col.type === "Date") text = fmtDate(v);
                    else if (col.type === "Bool") text = v ? "Yes" : "No";
                    else text = escapeHtml(v == null ? "–" : v);

                    return "<td class=\"" + cls.join(" ") + "\">" + text + "</td>";
                }).join("") + "</tr>";
            }).join("") + "</tbody>";
        }

        var table = document.createElement("table");
        table.innerHTML = thead + tbody;
        return table;
    }

    function appendSection(container, label, rs) {
        if (label) {
            var h = document.createElement("div");
            h.className = "eyebrow hc-section-head";
            h.textContent = label;
            container.appendChild(h);
        }

        // A result set that emits totalRowCount (see GetExceptionCenterDetailAsync's
        // "TotalMatchCount" sentinel column) discloses when its own TOP(N) cap
        // actually truncated the population, rather than letting rows.length
        // silently stand in for the true count and disagree with the summary
        // card's own Findings number.
        if (rs.totalRowCount != null && rs.totalRowCount > rs.rows.length) {
            var notice = document.createElement("div");
            notice.className = "hc-truncated-note";
            notice.textContent = "Showing the first " + rs.rows.length.toLocaleString("en-PH") +
                " of " + rs.totalRowCount.toLocaleString("en-PH") +
                " matching rows. Narrow the date range to see the rest.";
            container.appendChild(notice);
        }

        var panel = document.createElement("div");
        panel.className = "panel";
        var scroll = document.createElement("div");
        scroll.className = "gridscroll";
        scroll.appendChild(buildTable(rs));
        panel.appendChild(scroll);
        container.appendChild(panel);
    }

    /* ---------------- render dispatch ---------------- */

    function renderDetail(body, payload) {
        body.innerHTML = "";

        var sets = payload.resultSets || [];

        if (!sets.length) {
            body.innerHTML = "<div class=\"hc-empty\">No detail rows returned for this check.</div>";
            return;
        }

        if (sets.length === 3) {
            // The AR/AP tie-out shape: authoritative reconciliation, then the
            // check's own blind spots, then candidates — deliberately in that
            // order, so the candidate list reads as commentary, not proof.
            appendSection(body, "Reconciliation", sets[0]);
            appendSection(body, "What this check can't detect", sets[1]);
            appendSection(body, "Candidate contributors — not proof, see Note", sets[2]);
            return;
        }

        sets.forEach(function (rs, idx) {
            appendSection(body, sets.length > 1 ? ("Result set " + (idx + 1)) : null, rs);
        });
    }

    /* ---------------- modal factory ---------------- */

    /// <summary>
    /// config: {
    ///   veilId, titleId, subId, bodyId, closeBtnId  — element IDs owned by
    ///     the caller's own markup (kept as-is per consumer, e.g. Health
    ///     Check's hcVeil/hcTitle/hcSub/hcBody/hcCloseBtn).
    ///   url(key) -> string                            — builds the fetch URL
    ///     for a given row/card key (Health Check: ?seq=, Exception Center:
    ///     ?code=).
    /// }
    /// Returns { open(key, label), close(), wireCloseHandlers() }.
    function create(config) {
        function openModal() {
            document.body.classList.add("modal-open");
            $(config.veilId).style.display = "flex";
        }

        function closeModal() {
            document.body.classList.remove("modal-open");
            $(config.veilId).style.display = "none";
            $(config.bodyId).innerHTML = "";
        }

        function open(key, label) {
            $(config.titleId).textContent = label || String(key);
            $(config.subId).textContent = "Loading…";
            $(config.bodyId).innerHTML = "<div class=\"hc-empty\">Loading…</div>";
            openModal();

            fetch(config.url(key), { headers: { "X-Requested-With": "fetch" } })
                .then(function (r) {
                    if (!r.ok) {
                        return r.text().then(function (t) {
                            throw new Error(t || ("Request failed (" + r.status + ")"));
                        });
                    }
                    return r.json();
                })
                .then(function (payload) {
                    $(config.subId).textContent = "Generated " + payload.generatedAt;
                    renderDetail($(config.bodyId), payload);
                })
                .catch(function (e) {
                    $(config.subId).textContent = "";
                    $(config.bodyId).innerHTML = "<div class=\"hc-empty hc-error\">" + escapeHtml(e.message) + "</div>";
                });
        }

        function wireCloseHandlers() {
            var closeBtn = $(config.closeBtnId);
            if (closeBtn) closeBtn.addEventListener("click", closeModal);

            var veil = $(config.veilId);
            if (veil) {
                veil.addEventListener("click", function (e) {
                    if (e.target === veil) closeModal();
                });
            }

            document.addEventListener("keydown", function (e) {
                if (e.key === "Escape" && veil && veil.style.display !== "none") closeModal();
            });
        }

        return { open: open, close: closeModal, wireCloseHandlers: wireCloseHandlers };
    }

    /* ---------------- shared click/keyboard wiring for clickable rows/cards ---------------- */

    // Same click + Enter/Space activation pattern health-check.js originally
    // wired directly to tr.hc-row-clickable. Works for any clickable element
    // (table rows, card divs) as long as it already carries
    // tabindex="0" role="button" in its markup.
    function wireClickableElements(elements, onActivate) {
        elements.forEach(function (el) {
            el.addEventListener("click", function () { onActivate(el); });
            el.addEventListener("keydown", function (e) {
                if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    onActivate(el);
                }
            });
        });
    }

    global.CoreDrilldownModal = {
        create: create,
        wireClickableElements: wireClickableElements,
        escapeHtml: escapeHtml,
        fmtNum: fmtNum,
        fmtDate: fmtDate
    };
})(window);
