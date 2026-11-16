/*
 * QAYDAO — قسم «المرجعات» في الشريط الجانبي لـ Chatwoot.
 * returns-unified 2026-11-17 (قرار رامي: «مصدر واحد» لطلب الإرجاع في فريقي):
 * لم يعد هنا نموذج. الزران يفتحان فريقي — نفس النموذج الموحد الذي يغذّي المحاسب (استرداد المبلغ)
 * ومكتب الإرجاع (إرجاع المنتج وبوليصته) — ومعهما رقم المحادثة الحالية ليرتبط الطلب بها.
 * النسخة السابقة (نموذج داخل الشات): qaydao-returns-tab.js.bak-unified-20261117
 */
(function () {
  "use strict";
  if (window.__qd_returns_tab) return;
  window.__qd_returns_tab = true;

  var NAV_ID = "qd-returns-nav-item";
  var FAREEQI = /^stg-/.test(location.hostname) ? "https://stg-rami.qaydao.com" : "https://rami.qaydao.com";

  function convId() {
    var m = location.pathname.match(/\/conversations\/(\d+)/) || location.pathname.match(/\/inbox\/[^/]*\/(\d+)/);
    return m ? parseInt(m[1], 10) : null;
  }
  function openFareeqi(path) { window.open(FAREEQI + path, "_blank", "noopener"); }

  function findNav() {
    return document.querySelector('aside ul[class*="list-none"]')
        || document.querySelector('aside [class*="overflow-y-scroll"]')
        || document.querySelector("aside");
  }
  function buildNav() {
    var box = document.createElement("div");
    box.id = NAV_ID; box.setAttribute("dir", "rtl");
    box.style.cssText = "margin:4px 8px;font-family:Cairo,Tahoma,sans-serif;";

    var head = document.createElement("a");
    head.href = "#"; head.title = "المرجعات — من فريقي";
    head.innerHTML = '<span style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;flex:0 0 auto;font-size:15px;">🔄</span>' +
      '<span style="flex:1 1 auto;text-align:start;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">المرجعات</span>' +
      '<span id="qd-ret-caret" style="flex:0 0 auto;font-size:11px;transition:transform .15s;">▼</span>';
    head.style.cssText = "display:flex;align-items:center;gap:8px;padding:7px 10px;border-radius:8px;text-decoration:none;cursor:pointer;direction:rtl;font-weight:600;font-size:13.5px;color:#12403d;background:linear-gradient(135deg,rgba(31,95,91,.14),rgba(18,64,61,.10));border:1px solid rgba(31,95,91,.22);";

    var sub = document.createElement("div");
    sub.id = "qd-ret-sub";
    sub.style.cssText = "display:none;margin-top:4px;padding-inline-start:6px;";

    function subItem(icon, label, onClick) {
      var it = document.createElement("a");
      it.href = "#";
      it.innerHTML = '<span style="width:18px;text-align:center;flex:0 0 auto;font-size:13px;">' + icon + '</span>' +
        '<span style="flex:1 1 auto;text-align:start;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">' + label + '</span>' +
        '<span style="flex:0 0 auto;font-size:11px;opacity:.6">↗</span>';
      it.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;padding:6px 10px;border-radius:7px;text-decoration:none;cursor:pointer;direction:rtl;font-weight:500;font-size:12.8px;color:#2b4a47;background:rgba(31,95,91,.06);";
      it.onmouseenter = function () { it.style.background = "rgba(31,95,91,.16)"; };
      it.onmouseleave = function () { it.style.background = "rgba(31,95,91,.06)"; };
      it.onclick = function (e) { e.preventDefault(); onClick(); };
      return it;
    }
    sub.appendChild(subItem("➕", "طلب إرجاع / استرداد", function () {
      var c = convId();
      openFareeqi("/staff/orders-returns?tab=returns&new=1" + (c ? "&conv=" + c : ""));
    }));
    sub.appendChild(subItem("📋", "الطلبات المرفوعة", function () {
      openFareeqi("/staff/orders-returns?tab=returns");
    }));
    var note = document.createElement("div");
    note.textContent = "تُفتح في فريقي — نموذج واحد للمحاسب ومكتب الإرجاع";
    note.style.cssText = "margin:4px 2px 2px;font-size:11px;color:#5a6b6a;line-height:1.5;";
    sub.appendChild(note);

    head.onclick = function (e) {
      e.preventDefault();
      var open = sub.style.display !== "none";
      sub.style.display = open ? "none" : "block";
      var car = document.getElementById("qd-ret-caret");
      if (car) car.style.transform = open ? "rotate(0deg)" : "rotate(180deg)";
    };
    box.appendChild(head); box.appendChild(sub);
    return box;
  }
  function injectNav() {
    if (document.getElementById(NAV_ID)) return true;
    var nav = findNav(); if (!nav) return false;
    nav.insertBefore(buildNav(), nav.firstChild); return true;
  }
  function tryInject(n) { if (injectNav()) return; if (n > 0) setTimeout(function () { tryInject(n - 1); }, 400); }
  function start() {
    tryInject(15);
    var last = location.href;
    new MutationObserver(function () {
      if (location.href !== last) { last = location.href; setTimeout(function () { tryInject(10); }, 500); }
      if (!document.getElementById(NAV_ID)) tryInject(3);
    }).observe(document.documentElement, { subtree: true, childList: true });
  }
  if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", function () { setTimeout(start, 1200); }); }
  else { setTimeout(start, 1200); }
})();
