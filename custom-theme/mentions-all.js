/* QAYDAO — Mentions view: auto-select the "All" (الكل) assignee tab.
 * Chatwoot's Mentions view defaults to the "Mine" tab, which only shows
 * mentioned conversations assigned to you. Mentions usually happen in
 * conversations assigned to someone else, so they stay hidden. This switches
 * the Mentions view to the "All" tab automatically so every mention shows.
 * Robust: only acts on the mentions route, clicks once per visit.
 */
(function () {
  "use strict";
  if (window.__qd_mentions_all) return;
  window.__qd_mentions_all = true;

  var ALL_LABELS = ["الكل", "All"]; // tab label (ar / en)
  var doneForThisVisit = false;

  function onMentionsRoute() {
    return /\/mentions\/conversations/.test(location.pathname);
  }

  function findAllTab() {
    // assignee tabs render as <a> inside the ChatList header tabs <ul>
    var anchors = document.querySelectorAll("aside ~ * a, main a, .conversations-list a, a");
    // Narrow to short tab-like anchors whose trimmed text matches "الكل"/"All"
    var candidates = [];
    document.querySelectorAll("a").forEach(function (a) {
      var t = (a.textContent || "").trim();
      // tab label may include a count; take the leading word
      if (!t) return;
      for (var i = 0; i < ALL_LABELS.length; i++) {
        if (t === ALL_LABELS[i] || t.indexOf(ALL_LABELS[i]) === 0) {
          // must look like a tab (inside a ul of <= 4 items)
          var ul = a.closest("ul");
          if (ul && ul.querySelectorAll("a").length <= 4) candidates.push(a);
          break;
        }
      }
    });
    return candidates[0] || null;
  }

  function isActive(a) {
    // active tab has an underline pseudo + a color class; check aria/class hints
    var cls = a.className || "";
    return /text-n-slate-12|active|after:bg/.test(cls);
  }

  function tryClick(retries) {
    if (!onMentionsRoute() || doneForThisVisit) return;
    var tab = findAllTab();
    if (tab) {
      if (!isActive(tab)) tab.click();
      doneForThisVisit = true;
      return;
    }
    if (retries > 0) setTimeout(function () { tryClick(retries - 1); }, 400);
  }

  function start() {
    if (onMentionsRoute()) tryClick(15);
    var last = location.href;
    new MutationObserver(function () {
      if (location.href !== last) {
        last = location.href;
        doneForThisVisit = false; // reset on navigation
        if (onMentionsRoute()) setTimeout(function () { tryClick(15); }, 500);
      }
    }).observe(document.documentElement, { subtree: true, childList: true });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { setTimeout(start, 1200); });
  } else {
    setTimeout(start, 1200);
  }
})();
