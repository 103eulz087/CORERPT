/* ============================================================================
   CORE REPORTING PORTAL — report-center.js
   Card grid landing -> parameter bar -> generic Grid/Statement/Pivot renderer
   over the {columns, rows} JSON shape returned by ReportCenterController.
============================================================================ */
(function () {
    "use strict";

    var RISK = "#F87171";

    var state = {
        def: null,          // { proc, title, desc, render, accountRequired, zeroActivity, params: [] }
        lastQuery: null,    // query params actually used for the last successful run
        lastPayload: null
    };

    /* ---------------- helpers ---------------- */

    function $(id) { return document.getElementById(id); }

    function fmtNum(v) {
        if (v === null || v === undefined) return "–";
        var n = Number(v);
        if (Number.isInteger(n)) return n.toLocaleString("en-PH");
        return n.toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }

    function fmtAmt(v) {
        // Money-statement formatting: negatives in parentheses, oxblood text.
        if (v === null || v === undefined) return { text: "–", neg: false };
        var n = Number(v);
        var neg = n < 0;
        var s = Math.abs(n).toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        return { text: neg ? "(" + s + ")" : s, neg: neg };
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

    // Branch code -> branch name, read once from the parameter bar's own
    // dropdown (data-name attribute) so codes can be shown as names anywhere
    // in a rendered report without a second round-trip to the server.
    var branchMapCache = null;
    function getBranchMap() {
        if (branchMapCache) return branchMapCache;
        var map = {};
        var sel = $("pBranch");
        if (sel) {
            Array.prototype.forEach.call(sel.options, function (o) {
                if (o.value) map[o.value] = o.getAttribute("data-name") || o.text;
            });
        }
        branchMapCache = map;
        return map;
    }

    function branchDisplay(code) {
        if (code == null || code === "") return "All Branches";
        var key = String(code).trim();
        if (key.toUpperCase() === "ALL") return "All Branches";
        var map = getBranchMap();
        return map[key] || key;
    }

    function escapeHtml(s) {
        return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c];
        });
    }

    /* ---------------- landing <-> runner ---------------- */

    function showLanding() {
        $("rcLandingSection").style.display = "";
        document.getElementById("rcLanding").style.display = "";
        $("rcRunnerSection").style.display = "none";
    }

    function showRunner() {
        $("rcLandingSection").style.display = "none";
        document.getElementById("rcLanding").style.display = "none";
        $("rcRunnerSection").style.display = "";
    }

    function today() {
        var d = new Date();
        return d.toISOString().slice(0, 10);
    }
    function firstOfMonth() {
        var d = new Date();
        return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-01";
    }

    function openReport(card) {
        var ds = card.dataset;
        state.def = {
            proc: ds.proc,
            title: ds.title,
            desc: ds.desc,
            render: ds.render,
            accountRequired: ds.accountRequired === "true",
            zeroActivity: ds.zeroActivity === "true",
            liveActivity: ds.liveActivity === "true",
            params: ds.params ? ds.params.split(",") : []
        };
        state.lastQuery = null;
        state.lastPayload = null;

        $("rcTitle").textContent = state.def.title;
        $("rcDesc").textContent = state.def.desc;

        var has = function (p) { return state.def.params.indexOf(p) >= 0; };
        $("fldAsOfDate").style.display = has("AsOfDate") ? "" : "none";
        $("fldDateFrom").style.display = has("DateRange") ? "" : "none";
        $("fldDateTo").style.display = has("DateRange") ? "" : "none";
        $("fldBranch").style.display = has("Branch") ? "" : "none";
        $("fldAccount").style.display = has("Account") ? "" : "none";
        $("fldZeroActivity").style.display = state.def.zeroActivity ? "" : "none";
        $("fldLiveActivity").style.display = state.def.liveActivity ? "" : "none";

        $("lblAccount").textContent = "Account" + (state.def.accountRequired ? " (required)" : " (blank = all)");
        $("pAccount").placeholder = state.def.accountRequired
            ? "e.g. 101030101 — required for this report"
            : "e.g. 101030101 — blank = all accounts";

        $("pAsOfDate").value = today();
        $("pDateFrom").value = firstOfMonth();
        $("pDateTo").value = today();
        $("pBranch").value = "";
        $("pAccount").value = "";
        $("pIncludeZeroActivity").checked = false;
        // Default checked: the whole point of a "(Live)" report over its
        // non-Live sibling is seeing unposted current-period activity by
        // default; unchecking gives the tie-out/audit (posted-only) view.
        $("pIncludeLiveActivity").checked = true;

        $("rcValidation").style.display = "none";
        $("rcResultsWrap").style.display = "none";
        $("rcResults").innerHTML = "";

        showRunner();
        window.scrollTo(0, 0);
    }

    /* ---------------- query building + validation ---------------- */

    function buildQuery() {
        var def = state.def;
        var has = function (p) { return def.params.indexOf(p) >= 0; };
        var q = { procName: def.proc };

        if (has("AsOfDate") && $("pAsOfDate").value) q.asOfDate = $("pAsOfDate").value;
        if (has("DateRange") && $("pDateFrom").value) q.dateFrom = $("pDateFrom").value;
        if (has("DateRange") && $("pDateTo").value) q.dateTo = $("pDateTo").value;

        // "All Branches" -> omit the key entirely. Never post an empty string;
        // the sentinel for "all" is the query parameter being absent.
        if (has("Branch")) {
            var bc = $("pBranch").value;
            if (bc) q.branchCode = bc;
        }
        if (has("Account")) {
            var ac = $("pAccount").value.trim();
            if (ac) q.accountCode = ac;
        }
        if (def.zeroActivity) q.includeZeroActivity = $("pIncludeZeroActivity").checked ? "true" : "false";
        if (def.liveActivity) q.includeLiveActivity = $("pIncludeLiveActivity").checked ? "true" : "false";

        return q;
    }

    function validate(q) {
        var def = state.def;
        var has = function (p) { return def.params.indexOf(p) >= 0; };

        if (def.accountRequired && !q.accountCode) {
            return def.title + " requires a specific account code — it has no \"All Accounts\" mode.";
        }
        if (has("AsOfDate") && has("DateRange")) {
            // e.g. Consolidated GL — needs exactly one date input, not neither.
            if (!q.asOfDate && !(q.dateFrom && q.dateTo)) {
                return "Provide either an as-of date or a date range.";
            }
        } else if (has("AsOfDate") && !q.asOfDate) {
            return "An as-of date is required.";
        } else if (has("DateRange") && (!q.dateFrom || !q.dateTo)) {
            return "Both From and To dates are required.";
        }
        return null;
    }

    function qs(obj) {
        return Object.keys(obj)
            .filter(function (k) { return obj[k] !== undefined && obj[k] !== null && obj[k] !== ""; })
            .map(function (k) { return encodeURIComponent(k) + "=" + encodeURIComponent(obj[k]); })
            .join("&");
    }

    function showValidation(msg) {
        var box = $("rcValidation");
        box.textContent = msg;
        box.style.display = "";
    }

    /* ---------------- run ---------------- */

    function runReport() {
        var q = buildQuery();
        var err = validate(q);
        if (err) { showValidation(err); return; }

        $("rcValidation").style.display = "none";
        var btn = $("rcRunBtn");
        btn.disabled = true; btn.textContent = "Running…";

        fetch("/ReportCenter/RunReport?" + qs(q), { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (!r.ok) {
                    return r.text().then(function (t) {
                        throw new Error(t || ("Request failed (" + r.status + ")"));
                    });
                }
                return r.json();
            })
            .then(function (payload) {
                state.lastQuery = q;
                state.lastPayload = payload;
                renderResults(payload, q);
            })
            .catch(function (e) {
                showValidation(e.message);
                $("rcResultsWrap").style.display = "none";
            })
            .finally(function () {
                btn.disabled = false; btn.textContent = "Run report";
            });
    }

    function exportReport() {
        if (!state.lastQuery) { showValidation("Run the report before exporting."); return; }
        window.location = "/ReportCenter/Export?" + qs(state.lastQuery);
    }

    /* ---------------- rendering: dispatcher ---------------- */

    function renderResults(payload, q) {
        var results = $("rcResults");
        results.innerHTML = "";
        $("rcResultsWrap").style.display = "";

        var firstSet = payload.resultSets && payload.resultSets[0];
        var rowCount = firstSet ? firstSet.rows.length : 0;
        var branchLabel = q.branchCode
            ? ($("pBranch").selectedOptions[0] ? $("pBranch").selectedOptions[0].text : q.branchCode)
            : "All Branches";
        var period = q.asOfDate ? ("as of " + q.asOfDate) : (q.dateFrom ? (q.dateFrom + " to " + q.dateTo) : "");
        $("rcMeta").innerHTML = "<b>" + rowCount + "</b> row(s) &middot; " + escapeHtml(period) +
            " &middot; " + escapeHtml(branchLabel) +
            (q.accountCode ? " &middot; account " + escapeHtml(q.accountCode) : "");

        if (payload.renderStyle === "Statement") {
            renderStatement(payload.procName, payload.resultSets, results, q);
        } else if (payload.renderStyle === "PivotStatement") {
            renderPivot(payload.resultSets, results);
        } else if (/GLDetailTransactionReport/i.test(payload.procName)) {
            renderGlDetailTransactionReport(payload.resultSets, results);
        } else {
            renderGrid(payload.resultSets, results);
        }
    }

    /* ---------------- Grid renderer ---------------- */

    function renderGrid(resultSets, container) {
        resultSets.forEach(function (rs, idx) {
            if (resultSets.length > 1) {
                var h = document.createElement("div");
                h.className = "eyebrow";
                h.style.margin = "10px 0 6px";
                h.textContent = "Result set " + (idx + 1);
                container.appendChild(h);
            }
            var panel = document.createElement("div");
            panel.className = "panel";
            var scroll = document.createElement("div");
            scroll.className = "gridscroll";

            // Branch codes display as names — the column header stays
            // "Branch Code" (that's still what the field is), only the
            // value shown per row changes.
            var bcIdx = colIndex(rs.columns, "BranchCode");

            var table = document.createElement("table");
            var thead = "<thead><tr>" + rs.columns.map(function (c) {
                var n = c.type === "Number";
                return "<th class=\"" + (n ? "n" : "") + "\">" + escapeHtml(c.name) + "</th>";
            }).join("") + "</tr></thead>";

            var tbody = "<tbody>" + rs.rows.map(function (row) {
                return "<tr>" + row.map(function (v, i) {
                    var col = rs.columns[i];
                    if (i === bcIdx) return "<td>" + escapeHtml(branchDisplay(v)) + "</td>";
                    if (col.type === "Number") return "<td class=\"n mono\">" + fmtNum(v) + "</td>";
                    if (col.type === "Date") return "<td class=\"mono\">" + fmtDate(v) + "</td>";
                    if (col.type === "Bool") return "<td>" + (v ? "Yes" : "No") + "</td>";
                    return "<td>" + escapeHtml(v == null ? "" : v) + "</td>";
                }).join("") + "</tr>";
            }).join("") + "</tbody>";

            table.innerHTML = thead + tbody;
            scroll.appendChild(table);
            panel.appendChild(scroll);
            container.appendChild(panel);
        });
    }

    /* ---------------- GL Detail Transaction Report renderer ----------------
       Same {columns, rows} shape as renderGrid, but the result set is a
       sequence of per-account blocks: "Beginning Balance" (carries
       AccountCode/AccountDescription) -> detail rows (carry Reference,
       Debit/Credit, TicketNumber) -> "Current Period Change" (subtotal) ->
       "Ending Balance" (AccountCode/AccountDescription come back NULL on
       this row — the current account is tracked from the most recent
       Beginning Balance row instead of trusting Ending's own fields).
       Detail rows with a TicketNumber are clickable -> ticket drilldown. */

    function renderGlDetailTransactionReport(resultSets, container) {
        resultSets.forEach(function (rs, idx) {
            if (resultSets.length > 1) {
                var h = document.createElement("div");
                h.className = "eyebrow";
                h.style.margin = "10px 0 6px";
                h.textContent = "Result set " + (idx + 1);
                container.appendChild(h);
            }

            var iDesc = colIndex(rs.columns, "Trans Description");
            var iTicket = colIndex(rs.columns, "TicketNumber");
            var bcIdx = colIndex(rs.columns, "BranchCode");

            var panel = document.createElement("div");
            panel.className = "panel gltx";
            var scroll = document.createElement("div");
            scroll.className = "gridscroll";
            var table = document.createElement("table");

            var thead = "<thead><tr>" + rs.columns.map(function (c) {
                var n = c.type === "Number";
                return "<th class=\"" + (n ? "n" : "") + "\">" + escapeHtml(c.name) + "</th>";
            }).join("") + "</tr></thead>";

            var currentAccountCode = null;
            var currentAccountDesc = null;

            var tbody = "<tbody>" + rs.rows.map(function (row) {
                var marker = iDesc >= 0 ? String(row[iDesc] || "") : "";
                var isBegin = /^beginning balance$/i.test(marker);
                var isEnd = /^ending balance$/i.test(marker);
                var isSubtotal = /^current period change$/i.test(marker);
                var ticket = iTicket >= 0 ? row[iTicket] : null;
                var isDetail = !isBegin && !isEnd && !isSubtotal;

                if (isBegin) {
                    var acctIdx = colIndex(rs.columns, "Account ID");
                    var descIdx = colIndex(rs.columns, "Account Description");
                    currentAccountCode = acctIdx >= 0 ? row[acctIdx] : null;
                    currentAccountDesc = descIdx >= 0 ? row[descIdx] : null;
                }

                var rowClasses = [];
                if (isBegin) rowClasses.push("gl-marker", "gl-begin");
                if (isSubtotal) rowClasses.push("gl-marker", "gl-subtotal");
                if (isEnd) rowClasses.push("gl-marker", "gl-end");
                var clickable = isDetail && ticket;
                if (clickable) rowClasses.push("gl-detail");

                var cells = row.map(function (v, i) {
                    var col = rs.columns[i];
                    var cls = [];
                    if (i === iTicket && clickable) cls.push("tk");
                    if (i === bcIdx) return "<td class=\"" + cls.join(" ") + "\">" + escapeHtml(branchDisplay(v)) + "</td>";
                    if (col.type === "Number") return "<td class=\"n mono " + cls.join(" ") + "\">" + fmtNum(v) + "</td>";
                    if (col.type === "Date") return "<td class=\"mono " + cls.join(" ") + "\">" + fmtDate(v) + "</td>";
                    if (col.type === "Bool") return "<td class=\"" + cls.join(" ") + "\">" + (v ? "Yes" : "No") + "</td>";
                    return "<td class=\"" + cls.join(" ") + "\">" + escapeHtml(v == null ? "" : v) + "</td>";
                }).join("");

                var attrs = clickable
                    ? " data-ticket=\"" + escapeHtml(ticket) + "\" data-account-code=\"" + escapeHtml(currentAccountCode || "") +
                      "\" data-account-desc=\"" + escapeHtml(currentAccountDesc || "") + "\" tabindex=\"0\" role=\"button\""
                    : "";

                return "<tr class=\"" + rowClasses.join(" ") + "\"" + attrs + ">" + cells + "</tr>";
            }).join("") + "</tbody>";

            table.innerHTML = thead + tbody;
            scroll.appendChild(table);
            panel.appendChild(scroll);
            container.appendChild(panel);
        });
    }

    /* ---------------- Pivot renderer (Income Statement) ---------------- */

    function renderPivot(resultSets, container) {
        resultSets.forEach(function (rs) {
            var first = normName(rs.columns[0] && rs.columns[0].name);
            var label = first === "accountcode" ? "By Account"
                : (first === "metricorder" || first === "metricname") ? "Summary by Branch"
                : "Result set";
            var h = document.createElement("div");
            h.className = "eyebrow";
            h.style.margin = "10px 0 6px";
            h.textContent = label;
            container.appendChild(h);

            var panel = document.createElement("div");
            panel.className = "panel";
            var scroll = document.createElement("div");
            scroll.className = "gridscroll";
            var table = document.createElement("table");

            // Branch-code columns are dynamic (one per branch with activity
            // that period) — the code itself IS the column name here, so
            // swap the header text for the branch name where one is known.
            var bmap = getBranchMap();
            var lastIdx = rs.columns.length - 1;
            var thead = "<thead><tr>" + rs.columns.map(function (c, i) {
                var n = c.type === "Number";
                var isGrand = normName(c.name) === "grandtotal" || i === lastIdx;
                var headerText = bmap[c.name] || c.name;
                return "<th class=\"" + (n ? "n" : "") + "\">" + escapeHtml(headerText) +
                    (isGrand ? " &#9670;" : "") + "</th>";
            }).join("") + "</tr></thead>";

            var tbody = "<tbody>" + rs.rows.map(function (row) {
                return "<tr>" + row.map(function (v, i) {
                    var col = rs.columns[i];
                    var isGrand = i === lastIdx;
                    if (col.type === "Number") {
                        return "<td class=\"n mono" + (isGrand ? "" : "") + "\">" +
                            (isGrand ? "<b>" + fmtNum(v) + "</b>" : fmtNum(v)) + "</td>";
                    }
                    return "<td>" + escapeHtml(v == null ? "–" : v) + "</td>";
                }).join("") + "</tr>";
            }).join("") + "</tbody>";

            table.innerHTML = thead + tbody;
            scroll.appendChild(table);
            panel.appendChild(scroll);
            container.appendChild(panel);
        });
    }

    /* ---------------- Statement renderer ---------------- */

    function renderStatement(procName, resultSets, container, q) {
        // Explicit list, not a loose substring/regex: both Balance Sheet procs
        // (posted-only and Live) get the grouped statement view. A loose
        // pattern like /BalanceSheetWithDate/i does NOT match
        // "sp_rpt_BalanceSheetLiveWithDate" (the "Live" infix breaks the
        // contiguous substring), which would silently fall back to a flat
        // grid for the Live report — see CLAUDE.md-adjacent note in the
        // Report Center brief.
        if (procName === "sp_rpt_BalanceSheetWithDate" || procName === "sp_rpt_BalanceSheetLiveWithDate") {
            renderBalanceSheet(resultSets, container, q);
        } else if (/TrialBalanceWithDate/i.test(procName)) {
            renderTrialBalance(resultSets, container, q);
        } else {
            renderGrid(resultSets, container);
        }
    }

    function amtCell(v) {
        var f = fmtAmt(v);
        return "<td class=\"amt mono" + (f.neg ? " neg" : "") + "\">" + f.text + "</td>";
    }

    function renderBalanceSheet(resultSets, container, q) {
        var set0 = resultSets[0];
        if (!set0) { renderGrid(resultSets, container); return; }

        var iCode = colIndex(set0.columns, "AccountCode");
        var iDesc = colIndex(set0.columns, "AccountDescription");
        var iAmt = colIndex(set0.columns, "Amount");
        var iSection = colIndex(set0.columns, "BSSection");
        var iIndent = colIndex(set0.columns, "IndentLevel");

        if (iSection < 0) {
            // Enrichment failed upstream — fall back rather than invent grouping.
            renderGrid(resultSets, container);
            return;
        }

        var set1 = resultSets[1];
        var sIdx = set1 ? colIndex(set1.columns, "BSSection") : -1;
        var stIdx = set1 ? colIndex(set1.columns, "SectionTotal") : -1;
        var taIdx = set1 ? colIndex(set1.columns, "TotalAssets") : -1;
        var tlIdx = set1 ? colIndex(set1.columns, "TotalLiabilities") : -1;
        var teIdx = set1 ? colIndex(set1.columns, "TotalEquity") : -1;

        var sectionTotals = {};
        if (set1 && sIdx >= 0 && stIdx >= 0) {
            set1.rows.forEach(function (r) { sectionTotals[r[sIdx]] = r[stIdx]; });
        }
        var totalAssets = (set1 && taIdx >= 0 && set1.rows[0]) ? set1.rows[0][taIdx] : null;
        var totalLiabilities = (set1 && tlIdx >= 0 && set1.rows[0]) ? set1.rows[0][tlIdx] : null;
        var totalEquity = (set1 && teIdx >= 0 && set1.rows[0]) ? set1.rows[0][teIdx] : null;

        var sections = {};
        set0.rows.forEach(function (row) {
            var sec = row[iSection];
            if (sec == null) return;
            if (!sections[sec]) sections[sec] = [];
            sections[sec].push(row);
        });
        var order = Object.keys(sections).sort();

        var rowsHtml = "";
        var assetPrefixes = ["1", "2"], liabPrefixes = ["3", "4"];

        order.forEach(function (sec, idx) {
            var label = sec.replace(/^\d+-/, "");
            rowsHtml += "<tr class=\"lvl1\"><td>" + escapeHtml(label) + "</td><td class=\"amt\"></td></tr>";

            sections[sec].forEach(function (row) {
                var indent = iIndent >= 0 ? Number(row[iIndent]) : 1;
                var cls = indent >= 2 ? "lvl3" : "lvl2";
                rowsHtml += "<tr class=\"" + cls + "\"><td>" + escapeHtml(row[iDesc]) + "</td>" +
                    amtCell(row[iAmt]) + "</tr>";
            });

            var subtotal = sectionTotals.hasOwnProperty(sec) ? sectionTotals[sec] : null;
            rowsHtml += "<tr class=\"subtot\"><td class=\"lvl1\">Total " + escapeHtml(label) + "</td>" +
                amtCell(subtotal) + "</tr>";

            var prefix = sec.charAt(0);
            var next = order[idx + 1];
            var nextPrefix = next ? next.charAt(0) : null;

            if (assetPrefixes.indexOf(prefix) >= 0 && assetPrefixes.indexOf(nextPrefix) < 0 && totalAssets != null) {
                rowsHtml += "<tr class=\"grandtot\"><td>Total Assets</td>" + amtCell(totalAssets) + "</tr>";
            }
            if (liabPrefixes.indexOf(prefix) >= 0 && liabPrefixes.indexOf(nextPrefix) < 0 && totalLiabilities != null) {
                rowsHtml += "<tr class=\"subtot\"><td class=\"lvl1\">Total Liabilities</td>" + amtCell(totalLiabilities) + "</tr>";
            }
            if (prefix === "5" && totalLiabilities != null && totalEquity != null) {
                rowsHtml += "<tr class=\"grandtot\"><td>Total Liabilities and Equity</td>" +
                    amtCell(Number(totalLiabilities) + Number(totalEquity)) + "</tr>";
            }
        });

        // The line executives actually check first: does the statement
        // balance? Assets minus Liabilities minus Equity must read 0.00.
        if (totalAssets != null && totalLiabilities != null && totalEquity != null) {
            var diff = Number(totalAssets) - (Number(totalLiabilities) + Number(totalEquity));
            var balanced = Math.abs(diff) < 0.01;
            rowsHtml += "<tr class=\"checkline\"><td>Balance Check &mdash; Assets less Liabilities and Equity</td>" +
                "<td class=\"amt mono " + (balanced ? "ok" : "bad") + "\">" + fmtAmt(diff).text + "</td></tr>";
        }

        var branchLabel = q.branchCode
            ? ($("pBranch").selectedOptions[0] ? $("pBranch").selectedOptions[0].text : q.branchCode)
            : "All Branches (Consolidated)";

        container.innerHTML =
            "<div class=\"statement\">" +
            "<div class=\"stmthead\">" +
            "<div class=\"co\">CORE CS JFC &mdash; Meat Trading</div>" +
            "<div class=\"ti\">Statement of Financial Position</div>" +
            "<div class=\"dt\">As of " + escapeHtml(q.asOfDate || "") + " &middot; " + escapeHtml(branchLabel) + " &middot; in ₱</div>" +
            "</div>" +
            "<table class=\"stmt-tbl\">" + rowsHtml + "</table>" +
            "</div>";
    }

    function renderTrialBalance(resultSets, container, q) {
        var set0 = resultSets[0];
        if (!set0) { renderGrid(resultSets, container); return; }

        var abnIdx = colIndex(set0.columns, "Is Abnormal Balance");
        var bcIdx = colIndex(set0.columns, "Branch Code");

        var panel = document.createElement("div");
        panel.className = "panel";
        var scroll = document.createElement("div");
        scroll.className = "gridscroll";
        var table = document.createElement("table");

        var thead = "<thead><tr>" + set0.columns.map(function (c) {
            if (normName(c.name) === "isabnormalbalance") return "<th>Abnormal?</th>";
            var n = c.type === "Number";
            return "<th class=\"" + (n ? "n" : "") + "\">" + escapeHtml(c.name) + "</th>";
        }).join("") + "</tr></thead>";

        var tbody = "<tbody>" + set0.rows.map(function (row) {
            var abnormal = abnIdx >= 0 && !!row[abnIdx];
            var cells = row.map(function (v, i) {
                var col = set0.columns[i];
                if (i === abnIdx) {
                    return "<td>" + (v
                        ? "<span class=\"pill p-bad\">Abnormal</span>"
                        : "<span class=\"pill p-neu\">Normal</span>") + "</td>";
                }
                if (i === bcIdx) return "<td>" + escapeHtml(branchDisplay(v)) + "</td>";
                if (col.type === "Number") return "<td class=\"n mono\">" + fmtNum(v) + "</td>";
                if (col.type === "Date") return "<td class=\"mono\">" + fmtDate(v) + "</td>";
                return "<td>" + escapeHtml(v == null ? "" : v) + "</td>";
            }).join("");
            return "<tr class=\"" + (abnormal ? "tb-abn" : "") + "\">" + cells + "</tr>";
        }).join("") + "</tbody>";

        table.innerHTML = thead + tbody;
        scroll.appendChild(table);
        panel.appendChild(scroll);
        container.appendChild(panel);

        var set1 = resultSets[1];
        if (set1 && set1.rows.length) {
            var h = document.createElement("div");
            h.className = "eyebrow";
            h.style.margin = "10px 0 6px";
            h.textContent = "Totals";
            container.appendChild(h);
            renderGrid([set1], container);
        }
    }

    /* ---------------- Ticket drilldown modal ---------------- */

    function openTicketModal() {
        document.body.classList.add("modal-open");
        $("tkVeil").style.display = "flex";
    }

    function closeTicketModal() {
        document.body.classList.remove("modal-open");
        $("tkVeil").style.display = "none";
        $("tkBody").innerHTML = "";
    }

    function renderTicketModal(data) {
        var h = data.header;
        $("tkTitle").textContent = "Ticket " + h.ticketNumber;
        $("tkSub").textContent = h.mnemonic + " · " + h.status;

        var fields = [
            ["Ticket date", fmtDate(h.ticketDate)],
            ["Branch", branchDisplay(h.branchCode)],
            ["Reference no.", h.referenceNumber || "–"],
            ["Reference key", h.referenceKey || "–"],
            ["Origin", h.origin || "–"],
            ["Mnemonic", h.mnemonic || "–"],
            ["Status", h.status || "–"],
            ["Entered by", h.enteredBy || "–"],
            ["Checked by", h.checkedBy || "–"],
            ["Approved by", h.approvedBy || "–"]
        ];
        var fieldsHtml = "<div class=\"tk-fields\">" + fields.map(function (f) {
            return "<div class=\"f\"><span class=\"k\">" + escapeHtml(f[0]) + "</span>" +
                "<span class=\"v" + (f[0] === "Ticket date" ? " mono" : "") + "\">" + escapeHtml(f[1]) + "</span></div>";
        }).join("") + "</div>";
        var remarksHtml = "<div class=\"f\" style=\"margin-bottom:16px\"><span class=\"k\">Remarks</span>" +
            "<span class=\"v\">" + escapeHtml(h.remarks || "–") + "</span></div>";

        var totalDebit = 0, totalCredit = 0;
        var legRows = data.legs.map(function (l) {
            totalDebit += Number(l.debit) || 0;
            totalCredit += Number(l.credit) || 0;
            return "<tr><td class=\"mono\">" + escapeHtml(l.accountCode) + "</td>" +
                "<td>" + escapeHtml(l.accountTitle || "–") + "</td>" +
                "<td class=\"n mono\">" + fmtNum(l.debit) + "</td>" +
                "<td class=\"n mono\">" + fmtNum(l.credit) + "</td>" +
                "<td>" + escapeHtml(l.particulars || "–") + "</td></tr>";
        }).join("");

        var balanced = Math.abs(totalDebit - totalCredit) < 0.005;
        var legsHtml =
            "<div class=\"tk-legs-wrap\"><table>" +
            "<thead><tr><th>Account</th><th>Title</th><th class=\"n\">Debit</th><th class=\"n\">Credit</th><th>Particulars</th></tr></thead>" +
            "<tbody>" + legRows + "</tbody>" +
            "<tfoot><tr><td colspan=\"2\">Total</td>" +
            "<td class=\"n\">" + fmtNum(totalDebit) + "</td>" +
            "<td class=\"n\">" + fmtNum(totalCredit) + "</td>" +
            "<td class=\"" + (balanced ? "ok" : "bad") + "\">" + (balanced ? "Balanced" : "OUT OF BALANCE") + "</td>" +
            "</tr></tfoot></table></div>";

        $("tkBody").innerHTML = fieldsHtml + remarksHtml + legsHtml;
    }

    function renderTicketNotFound(ticketNumber) {
        $("tkTitle").textContent = "Ticket " + ticketNumber;
        $("tkSub").textContent = "";
        $("tkBody").innerHTML = "<div class=\"tk-notfound\">Ticket “" + escapeHtml(ticketNumber) +
            "” was not found, or is not posted.</div>";
    }

    function openTicketDrilldown(ticketNumber) {
        $("tkTitle").textContent = "Ticket " + ticketNumber;
        $("tkSub").textContent = "";
        $("tkBody").innerHTML = "<div class=\"tk-notfound\">Loading…</div>";
        openTicketModal();

        fetch("/ReportCenter/TicketDrilldown?ticketNumber=" + encodeURIComponent(ticketNumber),
            { headers: { "X-Requested-With": "fetch" } })
            .then(function (r) {
                if (r.status === 404) { renderTicketNotFound(ticketNumber); return null; }
                if (!r.ok) throw new Error("Request failed (" + r.status + ")");
                return r.json();
            })
            .then(function (data) {
                if (data) renderTicketModal(data);
            })
            .catch(function (e) {
                $("tkBody").innerHTML = "<div class=\"tk-notfound\">" + escapeHtml(e.message) + "</div>";
            });
    }

    /* ---------------- wire up ---------------- */

    document.addEventListener("DOMContentLoaded", function () {
        document.querySelectorAll(".rcard").forEach(function (card) {
            card.addEventListener("click", function () { openReport(card); });
            card.addEventListener("keydown", function (e) {
                if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openReport(card); }
            });
        });

        $("rcBackBtn").addEventListener("click", showLanding);
        $("rcRunBtn").addEventListener("click", runReport);
        $("rcExportBtn").addEventListener("click", exportReport);
        $("rcResetBtn").addEventListener("click", function () {
            if (state.def) openReport(document.querySelector('.rcard[data-proc="' + state.def.proc + '"]'));
        });

        // Delegated: any GL Detail Transaction Report row with a ticket
        // number opens the drilldown modal, however the results panel was
        // most recently re-rendered.
        $("rcResults").addEventListener("click", function (e) {
            var row = e.target.closest("tr[data-ticket]");
            if (row) openTicketDrilldown(row.getAttribute("data-ticket"));
        });
        $("rcResults").addEventListener("keydown", function (e) {
            if (e.key !== "Enter" && e.key !== " ") return;
            var row = e.target.closest("tr[data-ticket]");
            if (row) { e.preventDefault(); openTicketDrilldown(row.getAttribute("data-ticket")); }
        });

        $("tkCloseBtn").addEventListener("click", closeTicketModal);
        $("tkVeil").addEventListener("click", function (e) {
            if (e.target === $("tkVeil")) closeTicketModal();
        });
        document.addEventListener("keydown", function (e) {
            if (e.key === "Escape" && $("tkVeil").style.display !== "none") closeTicketModal();
        });
    });
})();
