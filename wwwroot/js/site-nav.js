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
