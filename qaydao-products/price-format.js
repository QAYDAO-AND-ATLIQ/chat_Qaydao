// QAYDAO 2026-11-04 — customer-facing price formatting for the Captain search tool.
//
// ROOT CAUSE this fixes (conv 10818 / 10876):
//   Salla returns `price` / `sale_price` / `regular_price` BEFORE VAT, while the
//   storefront (with_tax=true) shows `taxed_price` = pre-tax x 1.15. The search tool
//   returned the pre-tax amount, rounded (1,917.98 -> "1918"), as THE price, and it is
//   the price of the CHEAPEST variant only. Captain quoted it verbatim:
//     tool 1918 / 2238  vs  storefront 2,205.68 (smallest size) ... 2,750.17 (largest)
//     conv 10876: tool 1975 = side-table variant only; the coffee table is 5,281.93.
//
// CONTRACT (read by qaydao_captain_ai_enhancements.rb price guard):
//   * every price is VAT-inclusive, exactly as shown on qaydao.com (2 decimals)
//   * top-level `vat_inclusive: true` (the guard ignores prices without this flag)
//   * `price_from` / `price_to` / `variants[]` when sizes/options differ in price
//   * `price_note` is a ready Arabic sentence ("يبدأ من ...") the model can reuse
'use strict';

const VAT_RATE = 0.15;

const r2 = (n) => Math.round(Number(n) * 100) / 100;
const num = (v) => (v === null || v === undefined || v === '' || isNaN(Number(v)) ? null : Number(v));

function inclVat(ex, taxable) {
  const n = num(ex);
  if (n === null) return null;
  return taxable === false ? r2(n) : r2(n * (1 + VAT_RATE));
}

function fmtSar(n) {
  if (n === null || n === undefined) return '';
  const fixed = Number(n).toFixed(2).replace(/\.00$/, '');
  const [i, d] = fixed.split('.');
  return i.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (d ? '.' + d : '');
}

// row: master_products row (price_regular, price_discounted, taxable, variants_json)
function customerPrices(row) {
  const taxable = row.taxable !== false; // NULL => store default (prices shown incl. VAT)
  const disc = num(row.price_discounted);
  const reg = num(row.price_regular);
  const curEx = disc !== null && disc > 0 ? disc : reg;
  const price = inclVat(curEx, taxable);
  const original = disc !== null && disc > 0 && reg !== null && reg > disc ? inclVat(reg, taxable) : null;

  // Variants written by the nightly reconcile from Salla `skus` (pre-tax amounts).
  let vs = Array.isArray(row.variants_json) ? row.variants_json : [];
  vs = vs.filter((v) => v && num(v.price) !== null && num(v.price) > 0);
  let variantsStale = false;
  if (vs.length && curEx !== null) {
    const minEx = Math.min(...vs.map((v) => num(v.price)));
    // Product-level price is the cheapest SKU in Salla. If they disagree the variants
    // are older than the last live price update (hub ingest) -> do not trust them.
    if (Math.abs(minEx - curEx) > 0.05) variantsStale = true;
  }

  const out = {
    price,
    original_price: original,
    discount_pct: original && original > price ? Math.round((1 - price / original) * 100) : null,
    price_from: null,
    price_to: null,
    has_variant_prices: false,
    variants: [],
    price_note: price !== null ? `${fmtSar(price)} ريال شامل الضريبة` : null,
  };

  if (vs.length && !variantsStale) {
    const priced = vs.map((v) => ({
      name: v.name || null,
      price: inclVat(v.price, taxable),
      original_price: num(v.regular_price) && num(v.regular_price) > num(v.price) ? inclVat(v.regular_price, taxable) : null,
    })).sort((a, b) => a.price - b.price);
    const from = priced[0].price;
    const to = priced[priced.length - 1].price;
    out.price_from = from;
    out.price_to = to;
    out.has_variant_prices = to - from > 0.5;
    out.variants = priced.slice(0, 8);
    if (out.has_variant_prices) {
      out.price_note = `يبدأ من ${fmtSar(from)} ريال شامل الضريبة ويختلف حسب المقاس/الخيار (حتى ${fmtSar(to)} ريال)`;
    }
  } else if (variantsStale) {
    out.price_note = `يبدأ من ${fmtSar(price)} ريال شامل الضريبة، وقد يختلف حسب المقاس/الخيار`;
    out.price_from = price;
  }
  return out;
}

const PRICE_POLICY =
  'كل الأسعار شاملة ضريبة القيمة المضافة كما تظهر في المتجر. إذا كان has_variant_prices=true فاذكر «يبدأ من» price_from ولا تذكر سعراً واحداً للمنتج. لا تحسب ولا تقدّر أي سعر.';

module.exports = { VAT_RATE, inclVat, fmtSar, customerPrices, PRICE_POLICY };
