/* QAYDAO 2026-11-04 — show server-side action-guard refusals to the agent.
 *
 * The stock dashboard store actions (assignAgent, toggleStatus) swallow API
 * errors and the components then show a SUCCESS toast; assignment is also
 * optimistic (the sidebar shows "none" even though the server refused).
 * This helper watches only the three guarded endpoints; when one returns a
 * 4xx JSON body with `qaydao_guard`, it
 *   1) hides the misleading stock toast and shows the server's Arabic message,
 *   2) re-fetches the conversation so the sidebar shows the real assignee/status.
 * Loaded via installation config DASHBOARD_SCRIPTS (/qaydao-action-guard.js).
 */
(function () {
  if (window.__qaydaoActionGuard) return;
  window.__qaydaoActionGuard = true;

  var RX = /\/api\/v1\/accounts\/\d+\/(?:conversations\/(\d+)\/(?:assignments|toggle_status)|bulk_actions)(?:[?#]|$)/;
  var box = null;
  var timer = null;

  function ensureBox() {
    if (box) return box;
    box = document.createElement('div');
    box.id = 'qaydao-guard-toast';
    box.setAttribute('role', 'alert');
    box.setAttribute('popover', 'manual');
    box.style.cssText = [
      'position:fixed', 'inset:auto', 'top:16px', 'left:50%', 'transform:translateX(-50%)',
      'margin:0', 'max-width:34rem', 'width:calc(100% - 2rem)', 'box-sizing:border-box',
      'padding:12px 16px', 'border:0', 'border-radius:10px', 'background:#b91c1c', 'color:#fff',
      'font:600 14px/1.6 system-ui,-apple-system,"Segoe UI",Tahoma,sans-serif',
      'direction:rtl', 'text-align:right', 'box-shadow:0 8px 24px rgba(0,0,0,.25)', 'cursor:pointer', 'z-index:2147483647'
    ].join(';');
    box.addEventListener('click', hide);
    document.body.appendChild(box);
    return box;
  }

  function hideStockToasts() {
    try {
      document.querySelectorAll('[popover]').forEach(function (el) {
        if (el !== box && el.matches(':popover-open') && el.className.indexOf('fixed top-4') !== -1) el.hidePopover();
      });
    } catch (e) { /* ignore */ }
  }

  function hide() {
    if (!box) return;
    try { box.hidePopover(); } catch (e) { box.style.display = 'none'; }
  }

  function show(message) {
    var el = ensureBox();
    el.textContent = message;
    var open = function () {
      hideStockToasts();
      try { if (el.matches(':popover-open')) el.hidePopover(); el.showPopover(); } catch (e) { el.style.display = 'block'; }
    };
    open();
    setTimeout(open, 350); // after the stock "success" toast has been pushed
    clearTimeout(timer);
    timer = setTimeout(hide, 9000);
  }

  function refresh(displayId) {
    try {
      var store = document.getElementById('app').__vue_app__.config.globalProperties.$store;
      if (displayId) store.dispatch('getConversation', Number(displayId));
    } catch (e) { /* ignore */ }
  }

  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__qaydaoUrl = typeof url === 'string' ? url : String(url || '');
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    var m = xhr.__qaydaoUrl && RX.exec(xhr.__qaydaoUrl);
    if (m) {
      xhr.addEventListener('load', function () {
        if (xhr.status < 400 || xhr.status >= 500) return;
        var data = null;
        try {
          data = (xhr.responseType === 'json') ? xhr.response : JSON.parse(xhr.responseText);
        } catch (e) { return; }
        if (!data || !data.qaydao_guard) return;
        show(data.message || data.error);
        refresh(m[1]);
      });
    }
    return origSend.apply(this, arguments);
  };
})();
