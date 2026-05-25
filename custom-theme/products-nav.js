/* QAYDAO — "إدارة المنتجات" as a sidebar nav item (not a floating button).
 * Injects a styled link into the Chatwoot sidebar nav, matching its look.
 * Robust: multiple fallback selectors, self-contained inline styles,
 * re-applies on SPA navigation. Re-check after Chatwoot upgrades.
 */
(function () {
  "use strict";
  if (window.__qd_products_nav) return;
  window.__qd_products_nav = true;

  var ITEM_ID = "qd-products-nav-item";

  function findNavContainer() {
    // Preferred: the main scrollable nav list in the sidebar
    var ul = document.querySelector('aside ul[class*="list-none"]');
    if (ul) return ul;
    // Fallback: scrollable nav area
    var scroll = document.querySelector('aside [class*="overflow-y-scroll"]');
    if (scroll) return scroll;
    // Fallback: any aside (the sidebar)
    return document.querySelector("aside");
  }

  function buildItem() {
    var a = document.createElement("a");
    a.id = ITEM_ID;
    a.href = "/products";
    a.target = "_blank";
    a.title = "إدارة المنتجات — QAYDAO";
    a.setAttribute("dir", "rtl");
    a.innerHTML =
      '<span style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;flex:0 0 auto;font-size:15px;">\uD83D\uDCE6</span>' +
      '<span style="flex:1 1 auto;text-align:start;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">إدارة المنتجات</span>';
    a.style.cssText =
      "display:flex;align-items:center;gap:8px;margin:4px 8px;padding:7px 10px;" +
      "border-radius:8px;text-decoration:none;cursor:pointer;direction:rtl;" +
      "font-family:Cairo,Tahoma,sans-serif;font-weight:600;font-size:13.5px;" +
      "color:#3A4A33;background:linear-gradient(135deg,rgba(122,135,92,.14),rgba(94,106,71,.10));" +
      "border:1px solid rgba(107,127,92,.22);transition:all .15s ease;";
    a.onmouseenter = function () {
      a.style.background = "linear-gradient(135deg,rgba(122,135,92,.28),rgba(94,106,71,.20))";
    };
    a.onmouseleave = function () {
      a.style.background = "linear-gradient(135deg,rgba(122,135,92,.14),rgba(94,106,71,.10))";
    };
    return a;
  }

  function inject() {
    if (document.getElementById(ITEM_ID)) return true;
    var nav = findNavContainer();
    if (!nav) return false;
    var item = buildItem();
    // Insert at the very top of the nav so it's prominent
    nav.insertBefore(item, nav.firstChild);
    return true;
  }

  function tryInject(retries) {
    if (inject()) return;
    if (retries > 0) setTimeout(function () { tryInject(retries - 1); }, 400);
  }

  function start() {
    tryInject(15);
    var last = location.href;
    new MutationObserver(function () {
      if (location.href !== last) {
        last = location.href;
        setTimeout(function () { tryInject(10); }, 500);
      }
      // re-inject if the sidebar re-rendered and dropped our item
      if (!document.getElementById(ITEM_ID)) tryInject(3);
    }).observe(document.documentElement, { subtree: true, childList: true });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { setTimeout(start, 1200); });
  } else {
    setTimeout(start, 1200);
  }
})();
