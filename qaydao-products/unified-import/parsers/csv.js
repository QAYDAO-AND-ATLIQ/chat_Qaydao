// Parse Salla CSV export (Arabic columns)
// Returns array of normalized products
const { parse } = require("csv-parse");

const safeStr = v => (v === null || v === undefined) ? null : String(v).trim() || null;
const safeNum = v => {
  const n = parseFloat(v);
  if (isNaN(n)) return null;
  if (n < 0) return 0;
  if (n > 999999999.99) return 999999999.99;
  return n;
};

function parseSallaCsv(buffer) {
  return new Promise((resolve, reject) => {
    const content = buffer.toString("utf-8").replace(/^\ufeff/, "");
    parse(content, {
      columns: true,
      skip_empty_lines: true,
      relax_quotes: true,
      relax_column_count: true,
      from_line: 2,
    }, (err, rows) => {
      if (err) return reject(err);

      const products = rows.map(row => {
        const sallaId = safeStr(row["No."]);
        const name = safeStr(row["أسم المنتج"]);
        if (!sallaId || !name) return null;

        const category = safeStr(row["تصنيف المنتج"]);
        const variants = [];
        for (let i = 1; i <= 10; i++) {
          const vn = row[`[${i}] الاسم`];
          const vv = row[`[${i}] القيمة`];
          if (vn && vv) variants.push({ name: vn.trim(), value: vv.trim() });
        }

        return {
          salla_id: sallaId,
          sku: safeStr(row["رمز المنتج sku"]),
          name,
          name_en: null,
          description: (safeStr(row["الوصف"]) || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 5000) || null,
          category_path: category,
          category_main: category ? category.split(",")[0].split(">")[0].trim() : null,
          product_type: safeStr(row["نوع المنتج"]),
          promo_label: safeStr(row["العنوان الترويجي"]),
          price_regular: safeNum(row["سعر المنتج"]) || 0,
          price_discounted: safeNum(row["السعر المخفض"]),
          quantity_available: parseInt(row["الكمية المتوفرة"]) || null,
          status: safeStr(row["حالة المنتج"]),
          weight: safeNum(row["وزن المنتج"]),
          image_url: safeStr(row["صورة المنتج"]),
          gallery_urls: [],
          variants,
          product_url: sallaId ? `https://qaydao.com/-/p${sallaId}` : null,
          dimensions: null,
        };
      }).filter(p => p !== null);

      resolve(products);
    });
  });
}

module.exports = { parseSallaCsv };
