// Parse Salla XML (Google Merchant feed RSS)
// Returns array of normalized products
const { XMLParser } = require("fast-xml-parser");

const safeStr = v => (v === null || v === undefined) ? null : String(v).trim() || null;
const safeNum = v => {
  if (v === null || v === undefined) return null;
  const cleaned = String(v).replace(/[^\d.,]/g, "").replace(",", ".");
  const n = parseFloat(cleaned);
  if (isNaN(n)) return null;
  if (n < 0) return 0;
  if (n > 999999999.99) return 999999999.99;
  return n;
};

function parseSallaXml(buffer) {
  const xml = buffer.toString("utf-8").replace(/^\ufeff/, "");
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: "@_",
    removeNSPrefix: true,  // strips g: prefix
    parseTagValue: false,  // keep strings as-is
    trimValues: true,
  });

  let doc;
  try {
    doc = parser.parse(xml);
  } catch (err) {
    throw new Error(`Invalid XML: ${err.message}`);
  }

  // Google Merchant feed: rss/channel/item[]
  const channel = doc?.rss?.channel;
  if (!channel) throw new Error("XML missing rss/channel — not a Salla product feed");

  let items = channel.item;
  if (!items) return [];
  if (!Array.isArray(items)) items = [items];

  return items.map(item => {
    const sallaId = safeStr(item.id || item.guid?.["#text"] || item.guid);
    const name = safeStr(item.title);
    if (!sallaId || !name) return null;

    // Pull additional images
    const gallery = [];
    if (item.additional_image_link) {
      const links = Array.isArray(item.additional_image_link) ? item.additional_image_link : [item.additional_image_link];
      links.forEach(l => { const s = safeStr(l); if (s) gallery.push(s); });
    }

    return {
      salla_id: sallaId,
      sku: safeStr(item.mpn || item.sku),
      name,
      name_en: null,
      description: (safeStr(item.description) || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 5000) || null,
      category_path: safeStr(item.product_type || item.google_product_category),
      category_main: (() => {
        const cat = safeStr(item.product_type || item.google_product_category);
        return cat ? cat.split(">")[0].trim() : null;
      })(),
      product_type: safeStr(item.product_type),
      promo_label: safeStr(item.promotion_id),
      price_regular: safeNum(item.price) || 0,
      price_discounted: safeNum(item.sale_price),
      quantity_available: parseInt(item.quantity) || null,
      status: safeStr(item.availability),  // 'in stock' | 'out of stock'
      weight: safeNum(item.shipping_weight),
      image_url: safeStr(item.image_link),
      gallery_urls: gallery,
      variants: [],
      product_url: safeStr(item.link),
      dimensions: null,
    };
  }).filter(p => p !== null);
}

module.exports = { parseSallaXml };
