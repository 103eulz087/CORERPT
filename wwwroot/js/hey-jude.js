/* ============================================================================
   CORE REPORTING PORTAL — hey-jude.js

   The "Hey Jude" page (Views/HeyJude/Index.cshtml): a chat log with a large
   avatar, and an ECharts panel that lives in an on-demand dialog rather than
   a permanent page card — it opens itself the moment an answer carries chart
   data, and stays closed (taking zero layout space) otherwise. Stateless —
   each question is one POST to /HeyJude/Ask, answered independently; no
   client-side conversation history is sent back to the server.

   The dialog reuses the same .modalveil/.modalbox open-close convention as
   the ticket drilldown and Health Check detail modals (see
   drilldown-modal.js): body.modal-open while open, veil click-outside and
   Escape both close it. It's implemented locally here rather than through
   that shared module because this dialog hosts a raw ECharts instance, not
   the generic column/row result-set table drilldown-modal.js renders.

   CSRF: the endpoint mutates nothing but still requires the antiforgery
   token (see [ValidateAntiForgeryToken] on HeyJudeController), read here
   from the <meta name="request-verification-token"> tag in _Layout.cshtml
   and sent as the header Program.cs configured (X-CSRF-TOKEN), since this
   is a JSON POST body, not a form post.

   JSON casing: ASP.NET Core's default Json() result camelCases property
   names, so the C# HeyJudeResponse/ChartSeries (Ok/Answer/Chart/Labels/...)
   arrive here as ok/answer/chart/labels/... — match that, not the C# casing.
============================================================================ */
(function () {
    "use strict";

    var log = document.getElementById("hjLog");
    var form = document.getElementById("hjForm");
    var input = document.getElementById("hjInput");
    var chartEl = document.getElementById("hjChart");
    var chartVeil = document.getElementById("hjChartVeil");
    var chartTitle = document.getElementById("hjChartTitle");
    var chartCloseBtn = document.getElementById("hjChartCloseBtn");
    var viewChartBtn = document.getElementById("hjViewChartBtn");
    var micBtn = document.getElementById("hjMicBtn");
    var voiceToggle = document.getElementById("hjVoiceToggle");
    var avatar = document.getElementById("hjAvatar");
    if (!form || !log || !input || !chartEl) return;

    var tokenMeta = document.querySelector('meta[name="request-verification-token"]');
    var token = tokenMeta ? tokenMeta.content : "";

    var BRINE = "#3B82F6", STEEL = "#94A3B8", LINE = "#334155";
    var chart, lastSeries = null;

    function peso(v) {
        return "₱" + Number(v).toLocaleString("en-PH",
            { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }

    function addMessage(text, who) {
        var div = document.createElement("div");
        div.className = "hj-msg " + who;
        div.textContent = text;
        log.appendChild(div);
        log.scrollTop = log.scrollHeight;
        return div;
    }

    /* ---------------- chart dialog: open/close ---------------- */

    function openChartDialog() {
        if (!chartVeil) return;
        document.body.classList.add("modal-open");
        chartVeil.style.display = "flex";
        // The container was display:none (or just now created) so ECharts
        // would have measured zero size — resize once it's actually visible.
        requestAnimationFrame(function () { if (chart) chart.resize(); });
    }

    function closeChartDialog() {
        if (!chartVeil) return;
        document.body.classList.remove("modal-open");
        chartVeil.style.display = "none";
    }

    if (chartCloseBtn) chartCloseBtn.addEventListener("click", closeChartDialog);
    if (chartVeil) {
        chartVeil.addEventListener("click", function (e) {
            if (e.target === chartVeil) closeChartDialog();
        });
    }
    document.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && chartVeil && chartVeil.style.display !== "none") closeChartDialog();
    });
    if (viewChartBtn) {
        viewChartBtn.addEventListener("click", function () {
            if (lastSeries) openChartDialog();
        });
    }

    function renderChart(series) {
        if (!series || !series.labels || series.labels.length === 0) {
            return; // no ranking/trend in this answer — leave any prior chart as-is, don't pop the dialog
        }

        lastSeries = series;
        if (chartTitle) chartTitle.textContent = series.title || "Chart";
        if (viewChartBtn) viewChartBtn.style.display = "";

        chart = chart || echarts.init(chartEl);

        var isLine = (series.type || "bar") === "line";
        chart.setOption({
            grid: { left: 70, right: 24, top: 20, bottom: 60 },
            tooltip: { trigger: "axis", valueFormatter: function (v) { return peso(v); } },
            xAxis: {
                type: "category",
                data: series.labels,
                axisLine: { lineStyle: { color: LINE } },
                axisLabel: { fontSize: 10, color: STEEL, rotate: series.labels.length > 5 ? 28 : 0 }
            },
            yAxis: {
                type: "value",
                axisLabel: {
                    fontSize: 10, color: STEEL,
                    formatter: function (v) { return "₱" + (v / 1000).toFixed(0) + "k"; }
                },
                splitLine: { lineStyle: { color: LINE } }
            },
            series: [{
                type: isLine ? "line" : "bar",
                data: series.values,
                itemStyle: { color: BRINE },
                lineStyle: isLine ? { color: BRINE, width: 2 } : undefined,
                smooth: isLine,
                barMaxWidth: 42
            }]
        }, true);

        openChartDialog();
    }

    function askQuestion(question) {
        if (!question) return;

        addMessage(question, "user");
        input.value = "";
        input.disabled = true;

        var thinking = addMessage("Thinking…", "bot pending");

        fetch("/HeyJude/Ask", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-CSRF-TOKEN": token
            },
            body: JSON.stringify({ question: question })
        })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                thinking.remove();
                var answer = (data && data.answer) || "Sorry, something went wrong.";
                addMessage(answer, "bot");
                renderChart(data && data.chart);
                speak(answer);
            })
            .catch(function () {
                thinking.remove();
                addMessage("Sorry, I couldn't reach the server. Please try again.", "bot");
            })
            .finally(function () {
                input.disabled = false;
                input.focus();
            });
    }

    form.addEventListener("submit", function (e) {
        e.preventDefault();
        askQuestion(input.value.trim());
    });

    window.addEventListener("resize", function () {
        if (chart) chart.resize();
    });

    /* ---------------- voice: speak the answer (SpeechSynthesis) ----------------
       Broadly supported (Chrome/Edge/Safari) unlike SpeechRecognition below, so
       this half of "voice" degrades much less often. Toggle state is a
       per-viewer convenience (which browser tab happens to have audio on),
       so localStorage is the right place for it — never anything the server
       needs to know or that should sync across devices. */
    var VOICE_KEY = "hjVoiceRepliesOn";
    var synthAvailable = "speechSynthesis" in window;
    var voiceOn = synthAvailable;
    try {
        var stored = localStorage.getItem(VOICE_KEY);
        if (stored !== null) voiceOn = stored === "1";
    } catch (e) { /* private browsing / blocked storage — default stands */ }

    function updateVoiceToggleUi() {
        if (!voiceToggle) return;
        if (!synthAvailable) {
            voiceToggle.style.display = "none";
            return;
        }
        voiceToggle.textContent = "Voice replies: " + (voiceOn ? "on" : "off");
        voiceToggle.classList.toggle("off", !voiceOn);
    }

    // Toggled by both halves of "voice" below (speaking + listening) so the
    // avatar image feels like it's part of the same conversation either way,
    // rather than two unrelated indicators. A static JPG can't lip-sync, so
    // "speaking" is a rhythmic glow/scale loop (see .hj-avatar.speaking in
    // site.css) — an illusion of animation, not literal mouth movement.
    function setAvatarState(state) {
        if (!avatar) return;
        avatar.classList.toggle("listening", state === "listening");
        avatar.classList.toggle("speaking", state === "speaking");
    }

    /* "Calm, authoritative, natural" voice — closer to a Liam-Neeson-style
       register than a robotic bass effect. The earlier version leaned on a
       heavy utter.pitch shift (0.55) to fake depth; browser pitch-shifting
       isn't real vocal resynthesis, so anything far from the 1.0 default
       warps the waveform and is exactly what read as "robotic" here. Fixed
       by flipping the approach: do almost nothing to pitch/rate, and instead
       prefer whichever INSTALLED voice is already naturally deep and
       well-regarded for sounding human, not synthetic — "Daniel" (Apple's
       British male voice) and "Alex" (Apple's flagship US male voice) are
       the closest common analogues available across most systems, both
       specifically chosen for being non-robotic, not just deep. SpeechSynth
       still exposes no true bass/EQ control and its audio never reaches a
       Web Audio graph a real filter could hook into — voice selection, not
       DSP, is what's doing the work here. Voice list loads asynchronously in
       some browsers (Chrome fires 'voiceschanged' after getVoices() first
       returns empty), so this is resolved lazily and cached once found. */
    var PITCH = 0.96;   // 0-2 range, 1 = default; only a hair below natural, to avoid the warped/robotic artifact a bigger shift causes
    var RATE = 0.97;    // 0.1-10 range, 1 = default; barely slower, for a measured cadence without sounding plodding
    var authoritativeVoice = null;
    var authoritativeVoiceResolved = false;

    function pickAuthoritativeVoice() {
        if (!synthAvailable) return null;
        var voices = window.speechSynthesis.getVoices();
        if (!voices || !voices.length) return null;
        authoritativeVoiceResolved = true;
        var byName = function (re) { return voices.find(function (v) { return re.test(v.name); }); };
        // Ordered by how natural/non-robotic each is generally regarded,
        // not just by depth: Daniel and Alex first (both known for sounding
        // human rather than synthetic), then other common deep male voices,
        // then any English voice, then whatever is first — so this never
        // leaves speech silently broken on a system where none of these
        // names exist.
        return byName(/\bDaniel\b/i)
            || byName(/\bAlex\b/i)
            || byName(/\b(David|George|Google UK English Male|Fred|Guy|Mark|Male)\b/i)
            || voices.find(function (v) { return v.lang && v.lang.toLowerCase().indexOf("en") === 0; })
            || voices[0];
    }

    if (synthAvailable) {
        authoritativeVoice = pickAuthoritativeVoice();
        window.speechSynthesis.addEventListener("voiceschanged", function () {
            if (!authoritativeVoiceResolved) authoritativeVoice = pickAuthoritativeVoice();
        });
    }

    function speak(text) {
        if (!synthAvailable || !voiceOn || !text) return;
        try {
            window.speechSynthesis.cancel(); // don't overlap a rapid follow-up question
            var utter = new SpeechSynthesisUtterance(text);
            utter.rate = RATE;
            utter.pitch = PITCH;
            if (authoritativeVoice) utter.voice = authoritativeVoice;
            utter.onstart = function () { setAvatarState("speaking"); };
            utter.onend = function () { setAvatarState("idle"); };
            utter.onerror = function () { setAvatarState("idle"); };
            window.speechSynthesis.speak(utter);
        } catch (e) { /* speech synthesis is best-effort, never block the UI on it */ }
    }

    if (voiceToggle) {
        updateVoiceToggleUi();
        voiceToggle.addEventListener("click", function () {
            voiceOn = !voiceOn;
            if (!voiceOn && synthAvailable) { window.speechSynthesis.cancel(); setAvatarState("idle"); }
            try { localStorage.setItem(VOICE_KEY, voiceOn ? "1" : "0"); } catch (e) { /* ignore */ }
            updateVoiceToggleUi();
        });
    }

    /* ---------------- voice: ask by speaking (SpeechRecognition) ----------------
       Chrome/Edge support this well; desktop Safari does not (as of this
       writing) — feature-detected, not assumed. Single-shot: click, speak one
       question, it transcribes and auto-submits, same as typing + Enter. */
    var SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;

    if (!SpeechRecognitionCtor) {
        if (micBtn) {
            micBtn.disabled = true;
            micBtn.title = "Voice input isn't supported in this browser — try Chrome or Edge.";
        }
    } else if (micBtn) {
        var recognition = new SpeechRecognitionCtor();
        recognition.lang = "en-US";
        recognition.interimResults = false;
        recognition.maxAlternatives = 1;
        var listening = false;

        function setListening(on) {
            listening = on;
            micBtn.classList.toggle("listening", on);
            micBtn.setAttribute("aria-pressed", on ? "true" : "false");
            micBtn.textContent = on ? "Listening…" : "Speak";
            setAvatarState(on ? "listening" : "idle");
        }

        micBtn.addEventListener("click", function () {
            if (listening) { recognition.stop(); return; }
            if (synthAvailable) window.speechSynthesis.cancel(); // don't talk over the mic
            try {
                recognition.start();
                setListening(true);
            } catch (e) {
                // start() throws if already started elsewhere — ignore, UI stays as-is
            }
        });

        recognition.addEventListener("result", function (e) {
            var transcript = e.results[0][0].transcript;
            input.value = transcript;
            askQuestion(transcript.trim());
        });

        recognition.addEventListener("error", function (e) {
            setListening(false);
            if (e.error === "no-speech" || e.error === "aborted") return; // user just didn't say anything — no need to complain
            addMessage("I couldn't hear that (" + e.error + "). Try again or type your question.", "bot");
        });

        recognition.addEventListener("end", function () { setListening(false); });
    }
})();
