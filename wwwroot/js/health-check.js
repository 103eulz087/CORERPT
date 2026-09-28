/* ============================================================================
   CORE REPORTING PORTAL — health-check.js
   Thin wrapper around the shared drilldown-modal.js: wires Health Check's own
   modal markup/IDs (hcVeil/hcTitle/hcSub/hcBody/hcCloseBtn — unchanged, so
   Health.cshtml's existing markup needs no edits) and its own endpoint
   (/Dashboard/HealthCheckDetail?seq=) to the generic modal + table renderer.
   All rendering logic (the ~90 lines that used to live here) now lives once,
   in drilldown-modal.js, shared with Exception Center (exception-center.js).
============================================================================ */
(function () {
    "use strict";

    document.addEventListener("DOMContentLoaded", function () {
        if (!window.CoreDrilldownModal) return;

        var modal = window.CoreDrilldownModal.create({
            veilId: "hcVeil",
            titleId: "hcTitle",
            subId: "hcSub",
            bodyId: "hcBody",
            closeBtnId: "hcCloseBtn",
            url: function (seq) {
                return "/Dashboard/HealthCheckDetail?seq=" + encodeURIComponent(seq);
            }
        });
        modal.wireCloseHandlers();

        var rows = document.querySelectorAll("tr.hc-row-clickable[data-seq]");
        window.CoreDrilldownModal.wireClickableElements(rows, function (row) {
            modal.open(row.getAttribute("data-seq"), row.getAttribute("data-name"));
        });
    });
})();
