// QAYDAO Products - Sidebar Injection Script
(function() {
  'use strict';
  if (window.__qaydao_products_injected) return;
  window.__qaydao_products_injected = true;

  const BUTTON_ID = 'qaydao-products-nav-btn';

  function injectButton() {
    if (document.getElementById(BUTTON_ID)) return;

    const btn = document.createElement('a');
    btn.id = BUTTON_ID;
    btn.href = '/products';
    btn.target = '_blank';
    btn.title = 'إدارة المنتجات - QAYDAO';
    btn.innerHTML = '<span style="font-size:18px">📦</span><span>إدارة المنتجات</span>';
    btn.style.cssText = 'position:fixed;bottom:20px;left:20px;z-index:999999;background:linear-gradient(135deg,#7a875c 0%,#5e6a47 100%);color:white;padding:12px 18px;border-radius:50px;text-decoration:none;font-family:Cairo,Tahoma,sans-serif;font-weight:700;font-size:14px;box-shadow:0 4px 16px rgba(94,106,71,0.4);display:flex;align-items:center;gap:8px;transition:all 0.3s ease;cursor:pointer;direction:rtl;';
    btn.onmouseenter = function() {
      btn.style.transform = 'translateY(-2px)';
      btn.style.boxShadow = '0 6px 24px rgba(94,106,71,0.5)';
    };
    btn.onmouseleave = function() {
      btn.style.transform = 'translateY(0)';
      btn.style.boxShadow = '0 4px 16px rgba(94,106,71,0.4)';
    };

    document.body.appendChild(btn);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectButton);
  } else {
    injectButton();
  }

  // Re-inject on SPA route changes
  let lastUrl = location.href;
  new MutationObserver(function() {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      setTimeout(injectButton, 200);
    }
  }).observe(document, { subtree: true, childList: true });
})();
