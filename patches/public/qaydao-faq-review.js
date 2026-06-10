/* QAYDAO FAQ Review v1.0.0 (2026-06-10)
 * Adds a "تمت المراجعة" toggle button to every Captain FAQ response card
 * (https://chat.qaydao.com/app/accounts/1/captain/...) + a progress chip.
 * No Vue rebuild: maps DOM cards -> API records by intercepting the
 * assistant_responses XHR/fetch traffic, reuses the same auth headers for PATCH.
 * Backend counterpart: patches/initializers/qaydao_faq_review.rb
 */
(function () {
  'use strict';
  if (window.__qaydaoFaqReview) return;
  window.__qaydaoFaqReview = true;

  var VERSION = '1.0.0';
  var API_RE = /\/captain\/assistant_responses/;
  var state = {
    records: new Map(),      // id -> record
    byQuestion: new Map(),   // normalized question -> [records]
    meta: null,              // {reviewed_count, review_total, ...}
    headers: null            // captured auth headers from real requests
  };

  function log() {
    try { console.debug.apply(console, ['[QAYDAO-FAQ]'].concat([].slice.call(arguments))); } catch (e) { /* noop */ }
  }
  function norm(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
  function onCaptainPage() { return /\/accounts\/\d+\/captain\//.test(location.pathname); }
  function accountId() {
    var m = location.pathname.match(/\/accounts\/(\d+)\//);
    return m ? m[1] : null;
  }

  /* ---------------- data ingestion ---------------- */
  function ingest(r) {
    if (!r || typeof r.id !== 'number' || typeof r.question !== 'string') return;
    state.records.set(r.id, r);
    var k = norm(r.question);
    var arr = state.byQuestion.get(k) || [];
    var i = -1;
    for (var j = 0; j < arr.length; j++) { if (arr[j].id === r.id) { i = j; break; } }
    if (i >= 0) arr[i] = r; else arr.push(r);
    state.byQuestion.set(k, arr);
  }

  function handlePayload(text) {
    var j;
    try { j = JSON.parse(text); } catch (e) { return; }
    if (!j) return;
    if (j.meta) state.meta = j.meta;
    var list = j.payload || (j.id ? [j] : null);
    if (list && list.forEach) { list.forEach(ingest); }
    scheduleRender();
  }

  /* ---------------- XHR / fetch interception ---------------- */
  var XO = XMLHttpRequest.prototype.open;
  var XS = XMLHttpRequest.prototype.send;
  var XH = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__q = { m: m, u: String(u || ''), h: {} };
    return XO.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
    if (this.__q) this.__q.h[k] = v;
    return XH.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var x = this;
    if (x.__q && API_RE.test(x.__q.u) && !x.__q.h.__qaydao) {
      if (Object.keys(x.__q.h).length) state.headers = x.__q.h;
      x.addEventListener('load', function () {
        try { handlePayload(x.responseText); } catch (e) { log('xhr parse err', e); }
      });
    }
    return XS.apply(this, arguments);
  };
  var OF = window.fetch;
  if (OF) {
    window.fetch = function (input, init) {
      var url = (typeof input === 'string') ? input : ((input && input.url) || '');
      var p = OF.apply(this, arguments);
      if (API_RE.test(url)) {
        p.then(function (res) {
          try { res.clone().text().then(handlePayload); } catch (e) { /* noop */ }
        }).catch(function () { /* noop */ });
      }
      return p;
    };
  }

  /* ---------------- PATCH ---------------- */
  function patchReviewed(id, val, cb) {
    var acc = accountId();
    if (!acc) { cb(false); return; }
    var x = new XMLHttpRequest();
    x.open('PATCH', '/api/v1/accounts/' + acc + '/captain/assistant_responses/' + id);
    if (x.__q) x.__q.h.__qaydao = '1';
    var h = state.headers || {};
    Object.keys(h).forEach(function (k) {
      if (/^content-type$/i.test(k) || k === '__qaydao') return;
      try { x.setRequestHeader(k, h[k]); } catch (e) { /* noop */ }
    });
    x.setRequestHeader('Content-Type', 'application/json');
    var csrf = document.querySelector('meta[name="csrf-token"]');
    if (csrf && csrf.content) { try { x.setRequestHeader('X-CSRF-Token', csrf.content); } catch (e) { /* noop */ } }
    x.onload = function () {
      if (x.status >= 200 && x.status < 300) {
        var updated = null;
        try { updated = JSON.parse(x.responseText); } catch (e) { /* noop */ }
        cb(true, updated);
      } else { log('PATCH failed', x.status, x.responseText && x.responseText.slice(0, 200)); cb(false); }
    };
    x.onerror = function () { cb(false); };
    x.send(JSON.stringify({ assistant_response: { reviewed: val } }));
  }

  /* ---------------- rendering ---------------- */
  function paint(btn, rec) {
    var on = !!rec.reviewed;
    var label = on ? '\u2713 \u062a\u0645\u062a \u0627\u0644\u0645\u0631\u0627\u062c\u0639\u0629' : '\u062a\u0645\u062a \u0627\u0644\u0645\u0631\u0627\u062c\u0639\u0629\u061f';
    var tip;
    if (on) {
      tip = '\u0631\u0627\u062c\u0639\u0647\u0627' + (rec.reviewed_by ? ' ' + rec.reviewed_by : '') +
            (rec.reviewed_at ? ' \u2022 ' + new Date(rec.reviewed_at * 1000).toLocaleString('ar-SA') : '') +
            ' \u2014 \u0627\u0636\u063a\u0637 \u0644\u0644\u0625\u0644\u063a\u0627\u0621';
    } else {
      tip = '\u0627\u0636\u063a\u0637 \u0644\u062a\u0645\u064a\u064a\u0632\u0647\u0627 \u0643\u0645\u064f\u0631\u0627\u062c\u064e\u0639\u0629';
    }
    if (btn.textContent !== label) btn.textContent = label;
    if (btn.title !== tip) btn.title = tip;
    if (btn.classList.contains('is-on') !== on) btn.classList.toggle('is-on', on);
  }

  function onClickBtn(ev) {
    ev.preventDefault();
    ev.stopPropagation();
    var btn = ev.currentTarget;
    var id = parseInt(btn.dataset.rid, 10);
    var rec = state.records.get(id);
    if (!rec || btn.disabled) return;
    var to = !rec.reviewed;
    btn.disabled = true;
    btn.classList.add('is-busy');
    patchReviewed(id, to, function (ok, updated) {
      btn.disabled = false;
      btn.classList.remove('is-busy');
      if (ok) {
        if (updated && updated.id) { ingest(updated); }
        else { rec.reviewed = to; rec.reviewed_at = to ? Math.floor(Date.now() / 1000) : null; ingest(rec); }
        if (state.meta && typeof state.meta.reviewed_count === 'number') {
          state.meta.reviewed_count += to ? 1 : -1;
          if (state.meta.reviewed_count < 0) state.meta.reviewed_count = 0;
        }
        render();
      } else {
        btn.classList.add('is-err');
        setTimeout(function () { btn.classList.remove('is-err'); }, 1500);
      }
    });
  }

  function renderChip() {
    var el = document.getElementById('qaydao-rv-chip');
    var m = state.meta;
    if (!onCaptainPage() || !m || typeof m.reviewed_count !== 'number' || typeof m.review_total !== 'number') {
      if (el) el.remove();
      return;
    }
    if (!el) {
      el = document.createElement('div');
      el.id = 'qaydao-rv-chip';
      el.dir = 'rtl';
      document.body.appendChild(el);
    }
    var pct = m.review_total ? Math.round((100 * m.reviewed_count) / m.review_total) : 0;
    var txt = '\u0645\u064f\u0631\u0627\u062c\u064e\u0639 ' + m.reviewed_count + ' / ' + m.review_total + ' (' + pct + '\u066a)';
    if (el.textContent !== txt) el.textContent = txt;
  }

  function render() {
    if (!onCaptainPage()) { renderChip(); return; }
    var spans = document.querySelectorAll('#app span.text-base.text-n-slate-12.line-clamp-1');
    var used = new Map();
    spans.forEach(function (sp) {
      var q = norm(sp.textContent);
      if (!q) return;
      var arr = state.byQuestion.get(q);
      if (!arr || !arr.length) return;
      var idx = used.get(q) || 0;
      var rec = arr[Math.min(idx, arr.length - 1)];
      used.set(q, idx + 1);
      var row = sp.parentElement;
      if (!row) return;
      var btn = row.querySelector('button.qaydao-rv-btn');
      if (!btn) {
        btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'qaydao-rv-btn';
        btn.dir = 'rtl';
        btn.addEventListener('click', onClickBtn);
        sp.insertAdjacentElement('afterend', btn);
      }
      if (btn.dataset.rid !== String(rec.id)) btn.dataset.rid = String(rec.id);
      paint(btn, rec);
    });
    renderChip();
  }

  var renderTimer = null;
  function scheduleRender() {
    if (renderTimer) clearTimeout(renderTimer);
    renderTimer = setTimeout(render, 200);
  }

  /* ---------------- styles ---------------- */
  var st = document.createElement('style');
  st.textContent = [
    '.qaydao-rv-btn{flex:none;margin-inline-start:8px;font-size:12px;line-height:1;padding:4px 10px;',
    'border-radius:9999px;border:1px solid #cbd5e1;background:#f8fafc;color:#475569;cursor:pointer;',
    'white-space:nowrap;font-family:inherit;transition:all .15s ease;}',
    '.qaydao-rv-btn:hover{border-color:#16a34a;color:#16a34a;}',
    '.qaydao-rv-btn.is-on{border-color:#16a34a;background:#ecfdf5;color:#15803d;font-weight:600;}',
    '.qaydao-rv-btn.is-busy{opacity:.5;cursor:wait;}',
    '.qaydao-rv-btn.is-err{border-color:#dc2626;background:#fef2f2;color:#b91c1c;}',
    '#qaydao-rv-chip{position:fixed;bottom:18px;inset-inline-start:18px;z-index:99999;',
    'background:rgba(17,24,39,.88);color:#fff;font-size:12.5px;padding:7px 14px;border-radius:9999px;',
    'box-shadow:0 4px 14px rgba(0,0,0,.25);pointer-events:none;font-family:inherit;}'
  ].join('');
  (document.head || document.documentElement).appendChild(st);

  /* ---------------- observers ---------------- */
  var mo = new MutationObserver(function (muts) {
    for (var i = 0; i < muts.length; i++) {
      var t = muts[i].target;
      if (t && t.id === 'qaydao-rv-chip') continue;
      if (t && t.classList && t.classList.contains('qaydao-rv-btn')) continue;
      scheduleRender();
      return;
    }
  });
  mo.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('popstate', scheduleRender);

  log('loaded v' + VERSION);
})();
