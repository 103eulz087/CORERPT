/* ============================================================================
   CORE REPORTING PORTAL — site-nav.js
   Off-canvas sidebar toggle for phone/tablet widths (see .side/.navveil/
   .navtoggle in site.css, breakpoint max-width:900px). Loaded from
   _Layout.cshtml on every page — the toggle button, drawer and veil markup
   live in the shared layout, not per-view.
============================================================================ */
(function () {
    "use strict";

    var toggle = document.getElementById("navToggle");
    var side = document.getElementById("sideNav");
    var veil = document.getElementById("navVeil");
    if (!toggle || !side || !veil) return;

    function isOpen() {
        return side.classList.contains("open");
    }

    function openNav() {
        side.classList.add("open");
        veil.classList.add("open");
        toggle.setAttribute("aria-expanded", "true");
    }

    function closeNav() {
        side.classList.remove("open");
        veil.classList.remove("open");
        toggle.setAttribute("aria-expanded", "false");
    }

    toggle.addEventListener("click", function () {
        if (isOpen()) { closeNav(); } else { openNav(); }
    });

    veil.addEventListener("click", closeNav);

    document.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && isOpen()) { closeNav(); }
    });

    // Navigating away should not leave the drawer open behind the next page.
    var links = side.querySelectorAll(".nav a");
    for (var i = 0; i < links.length; i++) {
        links[i].addEventListener("click", function () {
            if (isOpen()) { closeNav(); }
        });
    }
})();

/* ============================================================================
   Branch picker (top-bar filter, _Layout.cshtml)

   The <select multiple> is left at size="1" in markup so it reads as a
   normal one-line dropdown at rest. But size="1" on a multi-select renders
   a 1-row listbox, not a popup combobox — every branch after the first
   (001-DAVAO) was only reachable by scrolling inside that 1px-tall box,
   which looked like the picker was stuck. Expand the size on click so it
   behaves like a real dropdown; collapse it back on change/blur/Escape.
   Ctrl/Cmd-click still multi-selects branches once expanded.
============================================================================ */
(function () {
    "use strict";

    var picks = document.querySelectorAll(".branchpick");
    for (var i = 0; i < picks.length; i++) {
        (function (select) {
            if (select.options.length < 2) return;
            var expandedSize = Math.min(select.options.length, 8);

            function expand() {
                select.size = expandedSize;
                select.classList.add("expanded");
            }

            function collapse() {
                select.size = 1;
                select.classList.remove("expanded");
            }

            select.addEventListener("mousedown", function (e) {
                if (select.size > 1) return; // already open, let the click land
                e.preventDefault();
                expand();
                select.focus();
            });

            select.addEventListener("change", collapse);
            select.addEventListener("blur", collapse);
            select.addEventListener("keydown", function (e) {
                if (e.key === "Escape") { collapse(); select.blur(); }
            });
        })(picks[i]);
    }
})();
