/* QAYDAO — Custom folder unread/total counts in the Chatwoot sidebar.
 * Chatwoot CE does not render counts on custom views; this injects them.
 * Auth: reads the cw_d_session_info cookie (DeviseTokenAuth headers).
 * Counts: POST each view's filter payload to /conversations/filter → all_count.
 * Fragile by nature (depends on DOM + private API); re-check after upgrades.
 */
(function () {
  "use strict";
  if (window.__qd_counts) return;
  window.__qd_counts = true;

  var REFRESH_MS = 60000;
  var BADGE_CLASS = "qd-folder-count";

  function getAuth() {
    var m = document.cookie.match(/cw_d_session_info=([^;]+)/);
    if (!m) return null;
    try {
      var h = JSON.parse(decodeURIComponent(m[1]));
      if (!h["access-token"] || !h.uid || !h.client) return null;
      return {
        "access-token": h["access-token"],
        client: h.client,
        uid: h.uid,
        "token-type": "Bearer",
        "Content-Type": "application/json",
      };
    } catch (e) {
      return null;
    }
  }

  function accountId() {
    var m = location.pathname.match(/accounts\/(\d+)/);
    return m ? m[1] : null;
  }

  function styleBadge(el, count) {
    el.textContent = count > 99 ? "99+" : String(count);
    el.style.cssText =
      "display:inline-flex;align-items:center;justify-content:center;" +
      "min-width:20px;height:20px;padding:0 6px;margin-inline-start:8px;" +
      "background:" + (count > 0 ? "#6B7F5C" : "#C9D2BF") + ";color:#fff;" +
      "border-radius:10px;font-size:11px;font-weight:700;font-family:Cairo,Tahoma,sans-serif;" +
      "vertical-align:middle;line-height:20px;flex:0 0 auto;";
  }

  function placeBadge(viewId, count) {
    // sidebar link to this custom view
    var links = document.querySelectorAll('a[href*="custom_view/' + viewId + '"]');
    links.forEach(function (link) {
      var badge = link.querySelector("." + BADGE_CLASS);
      if (!badge) {
        badge = document.createElement("span");
        badge.className = BADGE_CLASS;
        // place inside the link's label row
        var label = link.querySelector("span, div") || link;
        (label.parentNode || link).appendChild(badge);
      }
      styleBadge(badge, count);
    });
  }

  async function refresh() {
    var acc = accountId();
    var h = getAuth();
    if (!acc || !h) return;
    try {
      var res = await fetch(
        "/api/v1/accounts/" + acc + "/custom_filters?filter_type=conversation",
        { headers: h, credentials: "include" }
      );
      if (!res.ok) return;
      var views = await res.json();
      if (!Array.isArray(views)) return;
      for (var i = 0; i < views.length; i++) {
        var v = views[i];
        var payload = v.query && v.query.payload;
        if (!payload) continue;
        try {
          var fr = await fetch(
            "/api/v1/accounts/" + acc + "/conversations/filter?page=1",
            { method: "POST", headers: h, credentials: "include", body: JSON.stringify({ payload: payload }) }
          );
          if (!fr.ok) continue;
          var data = await fr.json();
          var count =
            (data.meta && (data.meta.all_count != null ? data.meta.all_count : data.meta.count)) ||
            (data.payload ? data.payload.length : 0);
          placeBadge(v.id, count);
        } catch (e) {}
      }
    } catch (e) {}
  }

  function start() {
    refresh();
    setInterval(refresh, REFRESH_MS);
    // re-apply on SPA navigation
    var last = location.href;
    new MutationObserver(function () {
      if (location.href !== last) {
        last = location.href;
        setTimeout(refresh, 800);
      }
    }).observe(document.documentElement, { subtree: true, childList: true });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { setTimeout(start, 1500); });
  } else {
    setTimeout(start, 1500);
  }
})();
