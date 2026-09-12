/* ============================================================================
   CORE REPORTING PORTAL — health-check.js
   Drill-down modal behind each Health Check row. Fetches the generic
   { procName, renderStyle, generatedAt, resultSets: [{ columns, rows }] }
   shape from /Dashboard/HealthCheckDetail and renders it as one or more
   tables inside the shared modal component (.modalveil/.modalbox, the same
   vocabulary the Report Center's ticket drilldown uses).

   Most checks return exactly one result set — rendered as a single grid,
   mirroring report-center.js's renderGrid formatting rules. Checks 12/13
   (the AR/AP subledger-vs-GL tie-outs) return three: the authoritative
   reconciliation, the check's own blind spots, and a capped list of
   candidate contributors whose Note text explicitly warns against treating
   them as proof — that Note is rendered in full, never truncated.
============================================================================ */
(function () {
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
        var panel = document.createElement("div");
        panel.className = "panel";
        var scroll = document.createElement("div");
        scroll.className = "gridscroll";
        scroll.appendChild(buildTable(rs));
        panel.appendChild(scroll);
        container.appendChild(panel);
    }

    /* ---------------- render dispatch ---------------- */

    function renderDetail(payload) {
        var body = $("hcBody");
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

    /* ---------------- modal open/close ---------------- */

    function openModal() {
        document.body.classList.add("modal-open");
        $("hcVeil").style.display = "flex";
    }

    function closeModal() {
        document.body.classList.remove("modal-open");
        $("hcVeil").style.display = "none";
        $("hcBody").innerHTML = "";
    }

    function openHealthDetail(seq, checkName) {
        $("hcTitle").textContent = checkName || ("Check " + seq);
        $("hcSub").textContent = "Loading…";
        $("hcBody").innerHTML = "<div class=\"hc-empty\">Loading…</div>";
        openModal();

        fetch("/Dashboard/HealthCheckDetail?seq=" + encodeURIComponent(seq),
            { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (!r.ok) {
                    return r.text().then(function (t) {
                        throw new Error(t || ("Request failed (" + r.status + ")"));
                    });
                }
                return r.json();
            })
            .then(function (payload) {
                $("hcSub").textContent = "Generated " + payload.generatedAt;
                renderDetail(payload);
            })
            .catch(function (e) {
                $("hcSub").textContent = "";
                $("hcBody").innerHTML = "<div class=\"hc-empty hc-error\">" + escapeHtml(e.message) + "</div>";
            });
    }

    /* ---------------- wire up ---------------- */

    document.addEventListener("DOMContentLoaded", function () {
        var rows = document.querySelectorAll("tr.hc-row-clickable[data-seq]");

        rows.forEach(function (row) {
            row.addEventListener("click", function () {
                openHealthDetail(row.getAttribute("data-seq"), row.getAttribute("data-name"));
            });
            row.addEventListener("keydown", function (e) {
                if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    openHealthDetail(row.getAttribute("data-seq"), row.getAttribute("data-name"));
                }
            });
        });

        var closeBtn = $("hcCloseBtn");
        if (closeBtn) closeBtn.addEventListener("click", closeModal);

        var veil = $("hcVeil");
        if (veil) {
            veil.addEventListener("click", function (e) {
                if (e.target === veil) closeModal();
            });
        }

        document.addEventListener("keydown", function (e) {
            if (e.key === "Escape" && veil && veil.style.display !== "none") closeModal();
        });
    });
})();
