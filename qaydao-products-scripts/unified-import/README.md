# Unified Import System

Single-upload, multi-platform product propagation for QAYDAO ecosystem.

## What it does

The employee uploads **one file** (CSV or XML from Salla) at `chat.qaydao.com/products/`. The system automatically fans it out to:

| Platform | DB | Key | Strategy |
|---|---|---|---|
| **Master Catalog** | PostgreSQL `master_products` | `salla_id` | Full upsert (this is the source of truth) |
| **Sales** | SQLite `/var/www/sales/database/database.sqlite` | `sku` | Upsert basics only — **never touches** `cost_price`, `shipping_cost`, `customs_cost`, `cbm`, dimensions |
| **Studio** | SQLite `/opt/qaydao-studio/app/database/database.sqlite` | `salla_product_id` | Upsert basics only — **never touches** AI fields (`color_family`, `material_primary`, `hero_eligible`, etc.) |

## What it does NOT do

- ❌ **Never deletes** any product. Products missing from the upload file are ignored (left as-is).
- ❌ Never overwrites employee-entered cost/shipping/customs fields in sales.
- ❌ Never overwrites AI/intelligence fields in studio.
- ❌ Does not replace the existing per-platform upload pages (`sales.qaydao.com/admin/product-xml-import` and `studio.qaydao.com/admin/products` continue to work as backup).

## Files

```
unified-import/
├── index.js                      ← orchestrator (called by server.js endpoint)
├── parsers/
│   ├── csv.js                    ← Salla CSV (Arabic columns)
│   └── xml.js                    ← Salla XML / Google Merchant feed
└── propagators/
    ├── master.js                 ← writes to PostgreSQL master_products
    ├── sales.js                  ← writes to SQLite sales (protects cost fields)
    └── studio.js                 ← writes to SQLite studio (protects AI fields)
```

## Endpoint

```
POST /products/api/upload-unified
  Content-Type: multipart/form-data
  Field: file (CSV or XML)
  Auth: session cookie
```

Returns:
```json
{
  "success": true,
  "result": {
    "started_at": "2026-05-21T21:37:09.460Z",
    "filename": "products.csv",
    "format": "csv",
    "products_parsed": 1234,
    "duration_ms": 5432,
    "master":  { "added": 50, "updated": 100, "unchanged": 1084, "errors": 0 },
    "sales":   { "added": 50, "updated": 100, "unchanged": 1080, "skipped_no_sku": 4, "protected_fields_kept": 100 },
    "studio":  { "added": 50, "updated": 100, "unchanged": 1084, "protected_fields_kept": 100 }
  }
}
```

## Field mapping

### Master ← unified
All fields from the unified product map directly.

### Sales ← unified (only these)
```
sku           ← p.sku                  (required — products without SKU are skipped)
name_ar       ← p.name
default_price ← p.price_regular
image         ← p.image_url            (COALESCE — keeps old if new is null)
description_ar← p.description          (COALESCE)
```
On INSERT only, sets `cost_price=0, shipping_cost=0, customs_cost=0` so the employee fills them in.

### Studio ← unified (only these)
```
title           ← p.name
title_ar        ← p.name
description(_ar)← p.description        (COALESCE)
price           ← p.price_regular
sale_price      ← p.price_discounted
image_url       ← p.image_url          (COALESCE)
availability    ← p.status             (normalized to 'in stock' | 'out of stock')
category        ← p.category_main      (COALESCE)
```

## Salla CSV format (employee export)

Expected columns (Arabic):
- `No.` → salla_id
- `أسم المنتج` → name
- `رمز المنتج sku` → sku
- `الوصف` → description (HTML stripped)
- `تصنيف المنتج` → category_path
- `سعر المنتج` → price_regular
- `السعر المخفض` → price_discounted
- `الكمية المتوفرة` → quantity_available
- `حالة المنتج` → status
- `صورة المنتج` → image_url

## Salla XML format (Google Merchant feed)

Expected RSS structure:
```xml
<rss><channel><item>
  <g:id>1104242398</g:id>
  <g:title>...</g:title>
  <g:price>...</g:price>
  <g:image_link>...</g:image_link>
  <g:availability>in stock</g:availability>
</item></channel></rss>
```

**Note**: Salla XML feeds rarely include SKU. Products without SKU are skipped from sales but still propagate to master and studio.

## Verification

Tested on `/var/www/sales/SAR.xml` (2,041 products from production):
- Parsed in <100ms
- Propagated to all 3 DBs in 2.4 seconds total
- Zero errors
- 2,039 sales-skipped due to missing SKU (expected for XML feed)
