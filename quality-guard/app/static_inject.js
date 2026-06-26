/* QAYDAO Quality Guard — Reports menu injector. Loaded via one <script> tag.
   Adds «تقارير الجودة» and «إعدادات الجودة» into the native Reports submenu.
   Renders the Quality Guard page inline. Admin-gating/identity handled by QG backend. */
(function () {
  "use strict";
  var QG_BASE = "/quality-guard";
  var FLAG = "data-qg-injected";

  function onReportsPage() {
    return /\/reports(\/|$)/.test(location.pathname);
  }

  function findContainer() {
    var links = document.querySelectorAll('a[href*="/reports/"]');
    if (!links.length) return null;
    var first = links[0];
    var parent = first.parentElement;
    for (var i = 0; i < 4 && parent; i++) {
      if (parent.querySelectorAll('a[href*="/reports/"]').length >= 2) {
        return { container: parent, sample: first };
      }
      parent = parent.parentElement;
    }
    return { container: first.parentElement, sample: first };
  }

  function makeItem(label, sample, onClick) {
    var node = sample.cloneNode(true);
    node.removeAttribute("href");
    node.setAttribute("role", "button");
    node.style.cursor = "pointer";
    var t = node.querySelector("span span") || node.querySelector("span") || node;
    t.textContent = label;
    node.classList.remove("router-link-active", "router-link-exact-active");
    node.addEventListener("click", function (e) {
      e.preventDefault(); e.stopPropagation();
      onClick();
      document.querySelectorAll(".qg-active").forEach(function (n) { n.classList.remove("qg-active"); });
      node.classList.add("qg-active");
    });
    node.setAttribute("data-qg-item", label);
    return node;
  }

  function ensureStyles() {
    if (document.getElementById("qg-inject-style")) return;
    var st = document.createElement("style");
    st.id = "qg-inject-style";
    st.textContent =
      ".qg-active{background:rgba(31,111,235,.12)!important;border-radius:8px}" +
      "#qg-frame-wrap{position:fixed;inset:0;z-index:50;display:none;background:#fff}" +
      "#qg-frame-wrap.show{display:block}" +
      "#qg-frame-wrap iframe{width:100%;height:100%;border:0}" +
      "#qg-frame-close{position:absolute;inset-inline-end:14px;top:10px;z-index:51;background:#1f6feb;color:#fff;border:0;border-radius:8px;padding:6px 12px;cursor:pointer;font-family:inherit}";
    document.head.appendChild(st);
  }

  function showQG(tab) {
    ensureStyles();
    var wrap = document.getElementById("qg-frame-wrap");
    if (!wrap) {
      wrap = document.createElement("div");
      wrap.id = "qg-frame-wrap";
      var close = document.createElement("button");
      close.id = "qg-frame-close";
      close.textContent = "\u2715 \u0625\u063a\u0644\u0627\u0642";
      close.addEventListener("click", function () { wrap.classList.remove("show"); });
      var frame = document.createElement("iframe");
      frame.id = "qg-frame";
      wrap.appendChild(close);
      wrap.appendChild(frame);
      document.body.appendChild(wrap);
    }
    document.getElementById("qg-frame").src = QG_BASE + "/?tab=" + (tab || "reports");
    wrap.classList.add("show");
  }

  function inject() {
    if (!onReportsPage()) return;
    var found = findContainer();
    if (!found || !found.container) return;
    if (found.container.getAttribute(FLAG)) return;
    var a = makeItem("\u062a\u0642\u0627\u0631\u064a\u0631 \u0627\u0644\u062c\u0648\u062f\u0629", found.sample, function () { showQG("reports"); });
    var b = makeItem("\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0627\u0644\u062c\u0648\u062f\u0629", found.sample, function () { showQG("settings"); });
    found.container.appendChild(a);
    found.container.appendChild(b);
    found.container.setAttribute(FLAG, "1");
  }

  function tick() { try { inject(); } catch (e) {} }
  function start() {
    new MutationObserver(tick).observe(document.body, { childList: true, subtree: true });
    setInterval(tick, 1500);
    tick();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else { start(); }
})();
