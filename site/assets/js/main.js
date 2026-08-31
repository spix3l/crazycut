(function () {
  "use strict";

  var doc = document.documentElement;

  /* ============================================================
     1. SCROLL REVEAL OBSERVER
     ============================================================ */
  try {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.08 });

    document.querySelectorAll(".reveal").forEach(function (el) {
      io.observe(el);
    });

    setTimeout(function () {
      document.querySelectorAll(".reveal:not(.in)").forEach(function (el) {
        el.classList.add("in");
      });
    }, 1200);
  } catch (e) { /* Scroll reveals are cosmetic */ }

  /* ============================================================
     2. THEME TOGGLE
     ============================================================ */
  try {
    var toggle = document.getElementById("theme-toggle");
    var meta = document.querySelector('meta[name="theme-color"]');
    var chromeColor = { dark: "#0d0e12", light: "#f4f5f8" };

    function currentTheme() {
      return doc.getAttribute("data-theme") === "light" ? "light" : "dark";
    }

    function syncThemeUI() {
      var theme = currentTheme();
      if (toggle) {
        toggle.setAttribute("aria-label", theme === "light" ? "Switch to dark theme" : "Switch to light theme");
      }
      if (meta) {
        meta.setAttribute("content", chromeColor[theme]);
      }
    }

    if (toggle) {
      syncThemeUI();
      toggle.addEventListener("click", function () {
        var next = currentTheme() === "light" ? "dark" : "light";
        try { localStorage.setItem("cc-theme", next); } catch (err) { /* private mode */ }
        if (next === "light") {
          doc.setAttribute("data-theme", "light");
        } else {
          doc.removeAttribute("data-theme");
        }
        syncThemeUI();
      });
    }
  } catch (e) { /* Theme toggle enhancement */ }

  /* ============================================================
     3. INTERACTIVE BEFORE / AFTER SPLIT SLIDER
     ============================================================ */
  try {
    var splitBox = document.getElementById("split-canvas");
    var paneAfter = document.getElementById("pane-after");
    var splitHandle = document.getElementById("split-handle");
    var isDragging = false;

    function updateSplitPosition(clientX) {
      if (!splitBox || !paneAfter || !splitHandle) return;
      var rect = splitBox.getBoundingClientRect();
      var offsetX = clientX - rect.left;
      var percentage = (offsetX / rect.width) * 100;
      if (percentage < 5) percentage = 5;
      if (percentage > 95) percentage = 95;

      paneAfter.style.width = percentage + "%";
      splitHandle.style.left = percentage + "%";
      var btn = splitHandle.querySelector(".handle-button");
      if (btn) btn.setAttribute("aria-valuenow", Math.round(percentage));
    }

    if (splitBox && splitHandle && paneAfter) {
      splitHandle.addEventListener("mousedown", function (e) {
        isDragging = true;
        e.preventDefault();
      });

      window.addEventListener("mouseup", function () {
        isDragging = false;
      });

      window.addEventListener("mousemove", function (e) {
        if (!isDragging) return;
        updateSplitPosition(e.clientX);
      });

      // Touch support
      splitHandle.addEventListener("touchstart", function (e) {
        isDragging = true;
      }, { passive: true });

      window.addEventListener("touchend", function () {
        isDragging = false;
      });

      window.addEventListener("touchmove", function (e) {
        if (!isDragging || !e.touches[0]) return;
        updateSplitPosition(e.touches[0].clientX);
      }, { passive: true });

      // Keyboard accessibility
      var handleBtn = splitHandle.querySelector(".handle-button");
      if (handleBtn) {
        handleBtn.addEventListener("keydown", function (e) {
          var current = parseFloat(splitHandle.style.left) || 50;
          if (e.key === "ArrowLeft" || e.key === "ArrowDown") {
            current = Math.max(5, current - 5);
            paneAfter.style.width = current + "%";
            splitHandle.style.left = current + "%";
            handleBtn.setAttribute("aria-valuenow", Math.round(current));
            e.preventDefault();
          } else if (e.key === "ArrowRight" || e.key === "ArrowUp") {
            current = Math.min(95, current + 5);
            paneAfter.style.width = current + "%";
            splitHandle.style.left = current + "%";
            handleBtn.setAttribute("aria-valuenow", Math.round(current));
            e.preventDefault();
          }
        });
      }
    }
  } catch (e) { /* Split slider */ }

  /* ============================================================
     4. FEATURE MODE TABS
     ============================================================ */
  try {
    var modeTabs = document.querySelectorAll(".hero-tab");
    var stageTitle = document.getElementById("stage-title");
    var stageBadge = document.getElementById("stage-badge");

    var modeContent = {
      shorts: {
        title: "Auto shorts: AI reframe and local Whisper transcription",
        badge: "whisper.cpp active"
      },
      tracking: {
        title: "Area tracking: Bounding box OpenCV optical flow",
        badge: "opencv 120fps"
      },
      timeline: {
        title: "Multi-track timeline: Zero-lag 4K ProRes scrubbing",
        badge: "c++17 ffi core"
      },
      captions: {
        title: "Local captions: Word-by-word timestamped subtitles",
        badge: "offline engine"
      }
    };

    modeTabs.forEach(function (tab) {
      tab.addEventListener("click", function () {
        modeTabs.forEach(function (t) {
          t.classList.remove("active");
          t.setAttribute("aria-selected", "false");
        });
        tab.classList.add("active");
        tab.setAttribute("aria-selected", "true");

        var mode = tab.getAttribute("data-mode");
        if (mode && modeContent[mode] && stageTitle && stageBadge) {
          stageTitle.textContent = modeContent[mode].title;
          stageBadge.textContent = modeContent[mode].badge;
        }
      });
    });
  } catch (e) { /* Tab switcher */ }

  /* ============================================================
     5. FAQ ACCORDION
     ============================================================ */
  try {
    var faqQuestions = document.querySelectorAll(".faq-question");
    faqQuestions.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var item = btn.closest(".faq-item");
        if (!item) return;
        var isActive = item.classList.contains("active");

        // Close other items
        document.querySelectorAll(".faq-item.active").forEach(function (activeItem) {
          if (activeItem !== item) {
            activeItem.classList.remove("active");
            var q = activeItem.querySelector(".faq-question");
            if (q) q.setAttribute("aria-expanded", "false");
          }
        });

        // Toggle current item
        if (isActive) {
          item.classList.remove("active");
          btn.setAttribute("aria-expanded", "false");
        } else {
          item.classList.add("active");
          btn.setAttribute("aria-expanded", "true");
        }
      });
    });
  } catch (e) { /* FAQ Accordion */ }

  /* ============================================================
     6. PLATFORM-AWARE DOWNLOAD PERMALINKS
     ============================================================ */
  try {
    var ua = navigator.userAgent;
    var platformLinks = null;

    if (/Win/i.test(navigator.platform) || /Windows/i.test(ua)) {
      platformLinks = {
        url: "https://github.com/spix3l/crazycut/releases/latest/download/CrazyCut-Windows.zip",
        label: "Download for Windows (x64)"
      };
    } else if (/Mac|iPhone|iPad|iPod/i.test(navigator.platform) || /Mac OS X/i.test(ua)) {
      platformLinks = {
        url: "https://github.com/spix3l/crazycut/releases/latest/download/CrazyCut.dmg",
        label: "Download for macOS (Universal)"
      };
    }

    if (platformLinks) {
      document.querySelectorAll("[data-download]").forEach(function (a) {
        a.setAttribute("href", platformLinks.url);
      });
      document.querySelectorAll("[data-download-text]").forEach(function (span) {
        span.textContent = platformLinks.label;
      });
    }
  } catch (e) { /* Download link detection */ }

  /* ============================================================
     7. GITHUB STARS FETCHER
     ============================================================ */
  try {
    fetch("https://api.github.com/repos/spix3l/crazycut")
      .then(function (res) { return res.json(); })
      .then(function (data) {
        if (data && typeof data.stargazers_count === "number") {
          var count = data.stargazers_count;
          var formatted = count >= 1000 ? (count / 1000).toFixed(1) + "k" : count.toString();
          document.querySelectorAll("[data-stars]").forEach(function (el) {
            el.textContent = formatted;
          });
        }
      })
      .catch(function () { /* Fallback to default count */ });
  } catch (e) { /* Star fetcher */ }

})();
