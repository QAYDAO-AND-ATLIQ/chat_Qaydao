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
      "#qg-frame-close{position:absolute;inset-inline-end:14px;top:10px;z-index:51;background:#1f6feb;color:#fff;border:0;border-radius:8px;padding:6px 12px;cursor:pointer;font-family:inherit}" +
      "body.qg-notes-hidden [data-qg-note-row]{display:none!important}" +
      "#qg-toggle-notes{cursor:pointer;border:1px solid #d2d6dc;background:#fff;color:#1f2d3d;border-radius:8px;padding:5px 12px;font-family:inherit;font-size:13px;margin-inline-start:8px;white-space:nowrap}" +
      "#qg-toggle-notes:hover{background:#f4f6f8}" +
      "#qg-toggle-notes.on{background:#fff8e8;border-color:#f0c36d;color:#9a6700}";
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

  // ---- Point 3: hide/show Quality Guard notes in the conversation view (no deletion) ----
  var QG_NOTE_MARK = "\u062a\u0646\u0628\u064a\u0647 \u062c\u0648\u062f\u0629 \u062f\u0627\u062e\u0644\u064a"; // «تنبيه جودة داخلي»
  var LBL_HIDE = "\u0625\u062e\u0641\u0627\u0621 \u062a\u0646\u0628\u064a\u0647\u0627\u062a \u0627\u0644\u062c\u0648\u062f\u0629"; // إخفاء تنبيهات الجودة
  var LBL_SHOW = "\u0625\u0638\u0647\u0627\u0631 \u062a\u0646\u0628\u064a\u0647\u0627\u062a \u0627\u0644\u062c\u0648\u062f\u0629"; // إظهار تنبيهات الجودة

  function tagQgNotes() {
    // find message bubbles that contain the QG marker; tag the closest message row
    var nodes = document.querySelectorAll("div,li,article,section");
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.getAttribute && el.getAttribute("data-qg-note-row")) continue;
      // shallow text check to avoid tagging huge containers
      if (el.children.length <= 6 && (el.textContent || "").indexOf(QG_NOTE_MARK) > -1) {
        // climb to the message-row wrapper (Chatwoot wraps each message)
        var row = el;
        for (var k = 0; k < 6 && row && row.parentElement; k++) {
          var cls = (row.className || "") + "";
          if (/message|conversation__message|wrap|bubble/i.test(cls)) break;
          row = row.parentElement;
        }
        if (row) row.setAttribute("data-qg-note-row", "1");
      }
    }
  }

  function isConversationView() {
    return /\/conversations?\//.test(location.pathname) || /\/(accounts)\/\d+\/(conversations|inbox)/.test(location.pathname);
  }

  function findTopBar() {
    // locate the top tabs «الرسائل» / «إدارة المنتجات» and return their shared container
    var cand = Array.prototype.slice.call(document.querySelectorAll("a,button,div,span"));
    var tab = null;
    for (var i = 0; i < cand.length; i++) {
      var t = (cand[i].textContent || "").trim();
      if (t === "\u0627\u0644\u0631\u0633\u0627\u0626\u0644" || t === "\u0625\u062f\u0627\u0631\u0629 \u0627\u0644\u0645\u0646\u062a\u062c\u0627\u062a") {
        tab = cand[i]; break;
      }
    }
    if (!tab) return null;
    // the tabs bar is usually the parent that holds both tabs
    var p = tab.parentElement;
    for (var j = 0; j < 4 && p; j++) {
      if ((p.textContent || "").indexOf("\u0627\u0644\u0631\u0633\u0627\u0626\u0644") > -1) return p;
      p = p.parentElement;
    }
    return tab.parentElement;
  }

  function injectToggle() {
    if (!isConversationView()) return;
    tagQgNotes();
    if (document.getElementById("qg-toggle-notes")) return;
    var bar = findTopBar();
    if (!bar) return;
    var btn = document.createElement("button");
    btn.id = "qg-toggle-notes";
    btn.type = "button";
    var hidden = document.body.classList.contains("qg-notes-hidden");
    btn.textContent = hidden ? LBL_SHOW : LBL_HIDE;
    if (hidden) btn.classList.add("on");
    btn.addEventListener("click", function (e) {
      e.preventDefault(); e.stopPropagation();
      var nowHidden = document.body.classList.toggle("qg-notes-hidden");
      tagQgNotes();
      btn.textContent = nowHidden ? LBL_SHOW : LBL_HIDE;
      btn.classList.toggle("on", nowHidden);
    });
    bar.appendChild(btn);
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

  function tick() { try { inject(); } catch (e) {} try { ensureStyles(); injectToggle(); } catch (e) {} }
  function start() {
    new MutationObserver(tick).observe(document.body, { childList: true, subtree: true });
    setInterval(tick, 1500);
    tick();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else { start(); }
})();
