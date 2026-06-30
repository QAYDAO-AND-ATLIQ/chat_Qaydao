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
      "#qg-toggle-notes{cursor:pointer}" +
      "#qg-toggle-notes.qg-toggle-on{color:#9a6700!important}";
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

  var LBL_MSGS = "\u0627\u0644\u0631\u0633\u0627\u0626\u0644";            // الرسائل
  var LBL_PRODS = "\u0625\u062f\u0627\u0631\u0629 \u0627\u0644\u0645\u0646\u062a\u062c\u0627\u062a"; // إدارة المنتجات

  function _leafText(el) {
    // text of an element treated as a tab label (small, few descendants)
    if (!el) return "";
    if (el.children && el.children.length > 4) return "";
    return (el.textContent || "").trim();
  }

  function _findTab(label) {
    var cand = document.querySelectorAll("a,button,div,span,li");
    for (var i = 0; i < cand.length; i++) {
      if (_leafText(cand[i]) === label) return cand[i];
    }
    return null;
  }

  // Return the actual tab element + its parent bar, ONLY when both tabs are siblings
  // (this guarantees we found the real conversation tab-bar, not a floating header).
  function findTabBar() {
    var prods = _findTab(LBL_PRODS);
    var msgs = _findTab(LBL_MSGS);
    if (!prods || !msgs) return null;
    // climb from each to find a common ancestor that directly holds BOTH as descendants
    // prefer the nearest shared parent
    var pa = prods;
    for (var d = 0; d < 5 && pa; d++) {
      if (pa.contains(msgs) && pa !== msgs) {
        // pa is a shared ancestor; use the level that holds both tab nodes
        return { bar: pa, sampleTab: prods };
      }
      pa = pa.parentElement;
    }
    return null;
  }

  function injectToggle() {
    if (!isConversationView()) return;
    tagQgNotes();
    if (document.getElementById("qg-toggle-notes")) return;
    var found = findTabBar();
    if (!found || !found.bar) return;
    // build the toggle as a clone of a real tab so it matches the tab design exactly
    var sample = found.sampleTab;
    var btn = sample.cloneNode(true);
    btn.id = "qg-toggle-notes";
    if (btn.tagName === "A") { btn.removeAttribute("href"); }
    btn.setAttribute("role", "button");
    btn.style.cursor = "pointer";
    btn.classList.remove("router-link-active", "router-link-exact-active", "active", "is-active");
    var hidden = document.body.classList.contains("qg-notes-hidden");
    // set the visible label text (replace inner text node, keep tab styling)
    var lblNode = btn.querySelector("span span") || btn.querySelector("span") || btn;
    lblNode.textContent = hidden ? LBL_SHOW : LBL_HIDE;
    if (hidden) btn.classList.add("qg-toggle-on");
    btn.addEventListener("click", function (e) {
      e.preventDefault(); e.stopPropagation();
      var nowHidden = document.body.classList.toggle("qg-notes-hidden");
      tagQgNotes();
      var ln = btn.querySelector("span span") || btn.querySelector("span") || btn;
      ln.textContent = nowHidden ? LBL_SHOW : LBL_HIDE;
      btn.classList.toggle("qg-toggle-on", nowHidden);
    });
    // insert right after the «إدارة المنتجات» tab, inside the same bar
    if (sample.parentElement) {
      sample.parentElement.insertBefore(btn, sample.nextSibling);
    } else {
      found.bar.appendChild(btn);
    }
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
