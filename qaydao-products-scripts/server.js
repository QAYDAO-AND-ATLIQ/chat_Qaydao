// QAYDAO Master Catalog Server (PostgreSQL backend)
require('dotenv').config();
const express = require('express');
const session = require('express-session');
const multer = require('multer');
const bcrypt = require('bcryptjs');
const rateLimit = require('express-rate-limit');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { parse } = require('csv-parse');

const db = require('./db-pg');
const adapters = require('./adapters');
const syncEngine = require('./sync-engine');
const captain = require('./captain-manager');
const unifiedImport = require('./unified-import');

const PORT = process.env.PORT || 3601;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'qaydao2026';
const ADMIN_HASH = bcrypt.hashSync(ADMIN_PASSWORD, 10);

const app = express();
app.set('trust proxy', 1);
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true }));

// Allow embedding in Chatwoot
app.use((req, res, next) => {
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('Content-Security-Policy', "frame-ancestors 'self' https://chat.qaydao.com");
  next();
});

app.use(session({
  secret: process.env.SESSION_SECRET || 'qaydao-default-secret',
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 30*24*60*60*1000, httpOnly: true, sameSite: 'lax' }
}));

const upload = multer({
  dest: path.join(__dirname, 'uploads'),
  limits: { fileSize: 50 * 1024 * 1024 }
});

const loginLimiter = rateLimit({ windowMs: 15*60*1000, max: 10 });
const searchLimiter = rateLimit({ windowMs: 60*1000, max: 100 });

function requireAuth(req, res, next) {
  if (req.session.authenticated) return next();
  if (req.headers.accept && req.headers.accept.includes('text/html')) {
    return res.redirect('/products/login');
  }
  return res.status(401).json({ error: 'غير مصرح' });
}

// ════════════════════════════════════════════════════════════
//  PUBLIC API: Search (used by Captain AI)
// ════════════════════════════════════════════════════════════

app.get('/products/api/search', searchLimiter, async (req, res) => {
  const t0 = Date.now();
  const q = String(req.query.q || req.query.query || '').trim();
  const category = String(req.query.category || '').trim() || null;
  const maxPrice = parseFloat(req.query.max_price) || null;
  const limit = Math.min(parseInt(req.query.limit) || 5, 20);
  const sessionHash = req.query.session ? crypto.createHash('sha256').update(req.query.session).digest('hex') : null;

  if (!q || q.length < 2) {
    return res.status(400).json({ error: 'Query too short' });
  }

  try {
    // PostgreSQL trigram search - much better than SQLite FTS for Arabic
    const rows = await db.all(`
      SELECT id, salla_id, sku, name, description, category_path, category_main,
             price_regular, price_discounted, status, quantity_available,
             promo_label, image_url, product_url, variants_json,
             similarity(name, $1) AS name_score
      FROM master_products
      WHERE deleted_at IS NULL
        AND is_active = TRUE
        AND (name % $1 OR name ILIKE $2 OR description ILIKE $2)
        AND ($3::TEXT IS NULL OR category_path ILIKE '%' || $3 || '%')
        AND ($4::NUMERIC IS NULL OR price_regular <= $4)
      ORDER BY name_score DESC NULLS LAST, price_regular ASC
      LIMIT $5
    `, [q, `%${q}%`, category, maxPrice, limit]);

    const products = rows.map(p => ({
      sku: p.sku,
      salla_id: p.salla_id,
      name: p.name,
      description: (p.description || '').slice(0, 200),
      category: p.category_main,
      price: parseFloat(p.price_discounted || p.price_regular),
      original_price: p.price_discounted ? parseFloat(p.price_regular) : null,
      status: p.status,
      type: p.promo_label,
      image: p.image_url,
      url: p.product_url,
      availability: (p.quantity_available || 0) > 0 || p.status === 'متاح' ? 'متوفر' : 'غير متوفر'
    }));

    const dt = Date.now() - t0;

    // Log to ai_events for ML
    db.query(`
      INSERT INTO ai_events (event_type, event_source, query_text, outcome, response_time_ms, session_hash, payload)
      VALUES ('product_search', 'captain_or_api', $1, $2, $3, $4, $5)
    `, [
      q,
      products.length > 0 ? 'found' : 'not_found',
      dt,
      sessionHash,
      JSON.stringify({ category, max_price: maxPrice, result_count: products.length, top_product_id: rows[0]?.id })
    ]).catch(e => console.error('[AI Event log error]', e.message));

    res.json({ success: true, query: q, count: products.length, products, response_time_ms: dt });
  } catch (err) {
    console.error('[Search]', err);
    res.status(500).json({ error: err.message });
  }
});

// ════════════════════════════════════════════════════════════
//  AUTH
// ════════════════════════════════════════════════════════════

app.get('/products/login', (req, res) => {
  if (req.session.authenticated) return res.redirect('/products');
  res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

app.post('/products/api/login', loginLimiter, (req, res) => {
  const { password } = req.body;
  if (!password) return res.status(400).json({ error: 'كلمة المرور مطلوبة' });
  if (!bcrypt.compareSync(password, ADMIN_HASH)) {
    return res.status(401).json({ error: 'كلمة المرور غير صحيحة' });
  }
  req.session.authenticated = true;
  res.json({ success: true });
});

app.post('/products/api/logout', (req, res) => {
  req.session.destroy(() => res.json({ success: true }));
});

// ════════════════════════════════════════════════════════════
//  EMPLOYEE UI
// ════════════════════════════════════════════════════════════

app.get('/products', requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Unified status - shows master + all 3 systems
app.get('/products/api/status', requireAuth, async (req, res) => {
  try {
    // Master Catalog stats
    const masterRow = await db.one(`
      SELECT
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE status = 'متاح') AS available,
        COUNT(*) FILTER (WHERE status = 'مخفي') AS hidden,
        COUNT(*) FILTER (WHERE quantity_available > 0) AS in_stock,
        COUNT(DISTINCT category_main) AS unique_categories,
        AVG(price_regular) AS avg_price,
        MIN(price_regular) AS min_price,
        MAX(price_regular) AS max_price
      FROM master_products
      WHERE deleted_at IS NULL
    `);

    // Last upload
    const lastUpload = await db.one(`
      SELECT * FROM upload_jobs
      WHERE status = 'completed'
      ORDER BY started_at DESC LIMIT 1
    `);

    let daysSinceUpload = null, freshness = 'never';
    if (lastUpload?.completed_at) {
      const ageMs = Date.now() - new Date(lastUpload.completed_at).getTime();
      daysSinceUpload = Math.floor(ageMs / (24*60*60*1000));
      freshness = daysSinceUpload < 7 ? 'fresh' : (daysSinceUpload < 14 ? 'warning' : 'stale');
    }

    // System stats (parallel)
    const [studioStats, salesStats, captainStats] = await Promise.all([
      adapters.studio.getStats(),
      adapters.sales.getStats(),
      adapters.captain.getStats(db.pool)
    ]);

    // AI events stats (last 7 days)
    const aiStats = await db.one(`
      SELECT
        COUNT(*) AS total_events,
        COUNT(DISTINCT session_hash) AS unique_sessions,
        AVG(response_time_ms)::INTEGER AS avg_response_ms,
        COUNT(*) FILTER (WHERE outcome = 'found') AS successful_searches,
        COUNT(*) FILTER (WHERE outcome = 'not_found') AS no_results
      FROM ai_events
      WHERE created_at > NOW() - INTERVAL '7 days'
    `);

    res.json({
      master: {
        total_products: parseInt(masterRow.total),
        available: parseInt(masterRow.available || 0),
        hidden: parseInt(masterRow.hidden || 0),
        in_stock: parseInt(masterRow.in_stock || 0),
        unique_categories: parseInt(masterRow.unique_categories || 0),
        price_range: {
          avg: parseFloat(masterRow.avg_price || 0).toFixed(2),
          min: parseFloat(masterRow.min_price || 0),
          max: parseFloat(masterRow.max_price || 0)
        }
      },
      systems: {
        studio: studioStats,
        sales: salesStats,
        captain: captainStats
      },
      last_upload: lastUpload ? {
        id: lastUpload.id,
        filename: lastUpload.filename,
        uploaded_at: lastUpload.completed_at,
        uploaded_by: lastUpload.uploaded_by,
        products_added: lastUpload.products_added,
        products_updated: lastUpload.products_updated,
        products_removed: lastUpload.products_removed,
        duration_ms: lastUpload.duration_ms,
        source: lastUpload.source
      } : null,
      days_since_upload: daysSinceUpload,
      freshness,
      ai_stats: {
        total_events: parseInt(aiStats?.total_events || 0),
        unique_sessions: parseInt(aiStats?.unique_sessions || 0),
        avg_response_ms: parseInt(aiStats?.avg_response_ms || 0),
        successful_searches: parseInt(aiStats?.successful_searches || 0),
        no_results: parseInt(aiStats?.no_results || 0)
      }
    });
  } catch (err) {
    console.error('[Status]', err);
    res.status(500).json({ error: err.message });
  }
});

// Top categories
app.get('/products/api/categories', requireAuth, async (req, res) => {
  try {
    const categories = await db.all(`
      SELECT category_main, COUNT(*) AS count
      FROM master_products
      WHERE deleted_at IS NULL AND category_main IS NOT NULL AND category_main != ''
      GROUP BY category_main
      ORDER BY count DESC LIMIT 20
    `);
    res.json({ categories });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Upload history
app.get('/products/api/uploads', requireAuth, async (req, res) => {
  try {
    const uploads = await db.all(`
      SELECT * FROM upload_jobs ORDER BY started_at DESC LIMIT 20
    `);
    res.json({
      uploads: uploads.map(u => ({
        id: u.id,
        filename: u.filename,
        file_size_mb: u.file_size ? (u.file_size / (1024*1024)).toFixed(2) : 'N/A',
        started_at: u.started_at,
        completed_at: u.completed_at,
        duration_ms: u.duration_ms,
        status: u.status,
        products_added: u.products_added,
        products_updated: u.products_updated,
        products_removed: u.products_removed,
        uploaded_by: u.uploaded_by,
        source: u.source,
        error_message: u.error_message
      }))
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Upload CSV
// ─── UNIFIED IMPORT (multi-platform fan-out) ──────────────────────────
// Accepts CSV or XML. Pushes to master_products + sales + studio.
// Skips deletes (never removes). Protects per-platform fields.
app.post('/products/api/upload-unified', requireAuth, upload.single('file'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'لم يتم تحميل أي ملف' });
  try {
    const fs = require('fs');
    const buffer = fs.readFileSync(req.file.path);
    const result = await unifiedImport.runUnifiedImport({
      buffer,
      filename: req.file.originalname,
      uploadedBy: req.session?.user || 'employee'
    });
    // Cleanup temp file
    try { fs.unlinkSync(req.file.path); } catch (e) {}
    res.json({ success: true, result });
  } catch (err) {
    console.error('[unified-upload]', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/products/api/upload', requireAuth, upload.single('csv'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'لم يتم تحميل أي ملف' });

  const startTime = Date.now();
  let jobId = null;

  try {
    // Backup file
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const backupPath = path.join(__dirname, 'backups', `${ts}_${req.file.originalname}`);
    fs.copyFileSync(req.file.path, backupPath);

    // Compute file hash
    const fileBuffer = fs.readFileSync(req.file.path);
    const fileSha = crypto.createHash('sha256').update(fileBuffer).digest('hex');

    // Count before
    const { rows: [before] } = await db.query('SELECT COUNT(*) AS n FROM master_products WHERE deleted_at IS NULL');

    // Create upload job
    const { rows: [job] } = await db.query(`
      INSERT INTO upload_jobs (filename, file_size, file_sha256, products_before, status, uploaded_by, source)
      VALUES ($1, $2, $3, $4, 'processing', $5, 'manual_csv')
      RETURNING id
    `, [req.file.originalname, req.file.size, fileSha, before.n, 'employee']);
    jobId = job.id;

    // Parse CSV
    const content = fileBuffer.toString('utf-8').replace(/^\ufeff/, '');
    const records = await new Promise((resolve, reject) => {
      parse(content, {
        columns: true,
        skip_empty_lines: true,
        relax_quotes: true,
        relax_column_count: true,
        from_line: 2
      }, (err, data) => err ? reject(err) : resolve(data));
    });

    // Track existing salla IDs
    const existing = await db.all(`SELECT salla_id FROM master_products WHERE deleted_at IS NULL`);
    const existingSet = new Set(existing.map(r => r.salla_id));
    const seenSet = new Set();

    let added = 0, updated = 0, skipped = 0;
    const cap = v => {
      const n = parseFloat(v);
      if (isNaN(n) || n === null) return null;
      if (n > 999999999.99) return 999999999.99;
      if (n < 0) return 0;
      return n;
    };
    const safeStr = v => v ? String(v).trim() : null;

    // Process in batches via async iteration
    for (const row of records) {
      const sallaId = safeStr(row['No.']);
      const name = safeStr(row['أسم المنتج']);
      if (!sallaId || !name) { skipped++; continue; }

      seenSet.add(sallaId);

      const category = safeStr(row['تصنيف المنتج']);
      const variants = [];
      for (let i = 1; i <= 10; i++) {
        const vn = row[`[${i}] الاسم`], vv = row[`[${i}] القيمة`];
        if (vn && vv) variants.push({ name: vn.trim(), value: vv.trim() });
      }

      const isUpdate = existingSet.has(sallaId);
      const hash = crypto.createHash('sha256').update(
        [sallaId, name, row['سعر المنتج'], row['السعر المخفض'], row['حالة المنتج']].join('|')
      ).digest('hex');

      try {
        await db.query(`
          INSERT INTO master_products (
            salla_id, sku, name, description, category_path, category_main,
            product_type, promo_label, price_regular, price_discounted,
            quantity_available, status, weight,
            image_url, variants_json, product_url, source, data_hash, source_updated_at
          ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,'salla',$17,NOW())
          ON CONFLICT (salla_id) DO UPDATE SET
            sku = EXCLUDED.sku, name = EXCLUDED.name, description = EXCLUDED.description,
            category_path = EXCLUDED.category_path, category_main = EXCLUDED.category_main,
            product_type = EXCLUDED.product_type, promo_label = EXCLUDED.promo_label,
            price_regular = EXCLUDED.price_regular, price_discounted = EXCLUDED.price_discounted,
            quantity_available = EXCLUDED.quantity_available, status = EXCLUDED.status,
            weight = EXCLUDED.weight, image_url = EXCLUDED.image_url,
            variants_json = EXCLUDED.variants_json, product_url = EXCLUDED.product_url,
            data_hash = EXCLUDED.data_hash, source_updated_at = NOW(),
            deleted_at = NULL
          WHERE master_products.data_hash IS DISTINCT FROM EXCLUDED.data_hash
        `, [
          sallaId, safeStr(row['رمز المنتج sku']), name,
          (safeStr(row['الوصف']) || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 2000),
          category, category ? category.split(',')[0].split('>')[0].trim() : null,
          safeStr(row['نوع المنتج']), safeStr(row['العنوان الترويجي']),
          cap(row['سعر المنتج']) || 0, cap(row['السعر المخفض']),
          parseInt(row['الكمية المتوفرة']) || null, safeStr(row['حالة المنتج']),
          cap(row['الوزن']),
          safeStr(row['صورة المنتج'])?.split(',')[0],
          JSON.stringify(variants),
          `https://qaydao.com/-/p${sallaId}`,
          hash
        ]);

        if (isUpdate) updated++; else added++;
      } catch (err) {
        skipped++;
        console.error(`[Upload] Row error for ${sallaId}:`, err.message.substring(0, 100));
      }
    }

    // Soft-delete missing products
    const toRemove = [...existingSet].filter(id => !seenSet.has(id));
    let removed = 0;
    if (toRemove.length > 0) {
      const result = await db.query(`
        UPDATE master_products SET deleted_at = NOW()
        WHERE salla_id = ANY($1) AND deleted_at IS NULL
      `, [toRemove]);
      removed = result.rowCount;
    }

    const dur = Date.now() - startTime;
    const { rows: [after] } = await db.query('SELECT COUNT(*) AS n FROM master_products WHERE deleted_at IS NULL');

    // Update job
    await db.query(`
      UPDATE upload_jobs
      SET status = 'completed', products_after = $1, products_added = $2,
          products_updated = $3, products_removed = $4, completed_at = NOW(),
          duration_ms = $5
      WHERE id = $6
    `, [after.n, added, updated, removed, dur, jobId]);

    fs.unlinkSync(req.file.path);

    res.json({
      success: true,
      added, updated, removed, skipped,
      after: after.n,
      duration_ms: dur,
      job_id: jobId
    });
  } catch (err) {
    if (req.file && fs.existsSync(req.file.path)) fs.unlinkSync(req.file.path);
    if (jobId) {
      await db.query(
        `UPDATE upload_jobs SET status = 'failed', error_message = $1, completed_at = NOW() WHERE id = $2`,
        [err.message, jobId]
      ).catch(() => {});
    }
    console.error('[Upload]', err);
    res.status(500).json({ error: 'فشل المعالجة', message: err.message });
  }
});

// Test search (employee dashboard)
app.get('/products/api/test-search', requireAuth, async (req, res) => {
  const q = String(req.query.q || '').trim();
  if (!q) return res.json({ products: [] });

  try {
    const rows = await db.all(`
      SELECT id, salla_id, sku, name, category_main, price_regular, price_discounted,
             status, image_url, product_url,
             similarity(name, $1) AS score
      FROM master_products
      WHERE deleted_at IS NULL AND (name % $1 OR name ILIKE $2 OR description ILIKE $2)
      ORDER BY score DESC NULLS LAST
      LIMIT 10
    `, [q, `%${q}%`]);
    res.json({ count: rows.length, products: rows });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// AI Events explorer
app.get('/products/api/ai-events', requireAuth, async (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit) || 50, 200);
    const events = await db.all(`
      SELECT id, event_type, event_source, query_text, outcome,
             response_time_ms, created_at, payload
      FROM ai_events
      ORDER BY created_at DESC LIMIT $1
    `, [limit]);

    // Aggregate by hour for last 24h
    const hourly = await db.all(`
      SELECT DATE_TRUNC('hour', created_at) AS hour,
             event_type,
             COUNT(*) AS count
      FROM ai_events
      WHERE created_at > NOW() - INTERVAL '24 hours'
      GROUP BY hour, event_type
      ORDER BY hour DESC
    `);

    res.json({ recent_events: events, hourly_stats: hourly });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Health
app.get('/products/api/health', async (req, res) => {
  try {
    const { rows: [r] } = await db.query('SELECT COUNT(*) AS n FROM master_products WHERE deleted_at IS NULL');
    res.json({
      status: 'ok',
      total_products: parseInt(r.n),
      version: '2.0-postgres-master'
    });
  } catch (err) {
    res.status(500).json({ status: 'error', error: err.message });
  }
});
// ════════════════════════════════════════════════════════════
//  SYNC ENGINE ENDPOINTS
// ════════════════════════════════════════════════════════════

// Trigger sync - both systems
app.post("/products/api/sync/all", requireAuth, async (req, res) => {
  const dryRun = req.query.dry_run === "true";
  try {
    const result = await syncEngine.syncAll({ dryRun });
    res.json({ success: true, ...result });
  } catch (err) {
    console.error("[Sync All]", err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Sync Studio only
app.post("/products/api/sync/studio", requireAuth, async (req, res) => {
  const dryRun = req.query.dry_run === "true";
  try {
    const result = await syncEngine.syncStudio({ dryRun });
    res.json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Sync Sales only
app.post("/products/api/sync/sales", requireAuth, async (req, res) => {
  const dryRun = req.query.dry_run === "true";
  try {
    const result = await syncEngine.syncSales({ dryRun });
    res.json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Get sync history (last 20 runs)
app.get("/products/api/sync/history", requireAuth, async (req, res) => {
  try {
    const events = await db.all(`
      SELECT id, event_source, outcome, response_time_ms, created_at, payload
      FROM ai_events WHERE event_type = 'sync_run'
      ORDER BY created_at DESC LIMIT 20
    `);
    res.json({ history: events });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});



// ════════════════════════════════════════════════════════════
//  CAPTAIN AI MANAGER ENDPOINTS
//  Allows employees to manage documents/FAQs/tools without
//  needing access to Chatwoot admin panel
// ════════════════════════════════════════════════════════════

// Dashboard for Captain manager
app.get("/products/captain", requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, "public", "captain.html"));
});

// Stats
app.get("/products/api/captain/stats", requireAuth, async (req, res) => {
  try {
    const stats = await captain.getStats();
    res.json(stats);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});


// ─── Captain Replies Viewer ───
app.get("/products/captain/replies", requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, "public", "captain-replies.html"));
});

app.get("/products/api/captain/replies", requireAuth, async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const channel = req.query.channel || null;
    const since_hours = parseInt(req.query.since_hours) || 24;
    const replies = await captain.listCaptainReplies({ limit, channel, since_hours });
    res.json({ replies, fetched_at: new Date().toISOString() });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});


// ─── Reply Control (teach + correct from replies page) ───

// ─── Captain Maintenance (pause/resume from dashboard) ───
app.get("/products/api/captain/status", requireAuth, async (req, res) => {
  try {
    const status = await captain.getCaptainStatus();
    res.json(status);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/products/api/captain/pause", requireAuth, async (req, res) => {
  try {
    const result = await captain.pauseCaptain();
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/products/api/captain/resume", requireAuth, async (req, res) => {
  try {
    const result = await captain.resumeCaptain();
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/products/api/captain/replies/:id/detail", requireAuth, async (req, res) => {
  try {
    const detail = await captain.getReplyDetail(req.params.id);
    res.json(detail);
  } catch (err) {
    res.status(404).json({ error: err.message });
  }
});

app.post("/products/api/captain/replies/teach", requireAuth, async (req, res) => {
  try {
    const { question, answer, source_msg_id } = req.body || {};
    const result = await captain.teachFromReply({
      question, answer, source_msg_id,
      reviewer: req.session?.user || 'admin'
    });
    res.json(result);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.get("/products/api/captain/replies/related-faq", requireAuth, async (req, res) => {
  try {
    const faqs = await captain.findRelatedFAQ(req.query.text || '');
    res.json({ faqs });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/products/api/captain/replies/stats", requireAuth, async (req, res) => {
  try {
    const since_hours = parseInt(req.query.since_hours) || 24;
    const [overall, by_channel] = await Promise.all([
      captain.getRepliesStats(since_hours),
      captain.getRepliesByChannel(since_hours)
    ]);
    res.json({ overall, by_channel });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});


// ─── Captain Learning System ───
app.get("/products/captain/learn", requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, "public", "captain-learn.html"));
});

app.get("/products/api/captain/learn/suggestions", requireAuth, async (req, res) => {
  try {
    const status = req.query.status || 'pending';
    const limit = parseInt(req.query.limit) || 50;
    const [suggestions, stats] = await Promise.all([
      captain.listLearningSuggestions(status, limit),
      captain.getLearningStats()
    ]);
    res.json({ suggestions, stats });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/products/api/captain/learn/suggestions/:id/context", requireAuth, async (req, res) => {
  try {
    const sug = await captain.getLearningSuggestion(req.params.id);
    if (!sug) return res.status(404).json({ error: 'not found' });
    const messages = await captain.fetchConversationContext(sug.conversation_id);
    res.json({ suggestion: sug, messages });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/products/api/captain/learn/suggestions/:id/approve", requireAuth, async (req, res) => {
  try {
    const { question, answer } = req.body || {};
    const result = await captain.approveLearningSuggestion(req.params.id, {
      question, answer, reviewer: req.session.user || 'admin'
    });
    res.json(result);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.post("/products/api/captain/learn/suggestions/:id/reject", requireAuth, async (req, res) => {
  try {
    const { reason } = req.body || {};
    const result = await captain.rejectLearningSuggestion(req.params.id, {
      reason, reviewer: req.session.user || 'admin'
    });
    res.json(result);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// ─── Documents CRUD ───
app.get("/products/api/captain/documents", requireAuth, async (req, res) => {
  try {
    const docs = await captain.listDocuments();
    res.json({ documents: docs });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/products/api/captain/documents/:id", requireAuth, async (req, res) => {
  try {
    const doc = await captain.getDocument(req.params.id);
    if (!doc) return res.status(404).json({ error: "Document not found" });
    res.json({ document: doc });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/products/api/captain/documents", requireAuth, async (req, res) => {
  try {
    const doc = await captain.createDocument(req.body);
    res.json({ success: true, document: doc });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.put("/products/api/captain/documents/:id", requireAuth, async (req, res) => {
  try {
    const doc = await captain.updateDocument(req.params.id, req.body);
    if (!doc) return res.status(404).json({ error: "Document not found" });
    res.json({ success: true, document: doc });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.delete("/products/api/captain/documents/:id", requireAuth, async (req, res) => {
  try {
    const ok = await captain.deleteDocument(req.params.id);
    res.json({ success: ok });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── FAQs CRUD ───
app.get("/products/api/captain/faqs", requireAuth, async (req, res) => {
  try {
    const faqs = await captain.listFAQs();
    res.json({ faqs });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/products/api/captain/faqs", requireAuth, async (req, res) => {
  try {
    const faq = await captain.createFAQ(req.body);
    res.json({ success: true, faq });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.put("/products/api/captain/faqs/:id", requireAuth, async (req, res) => {
  try {
    const faq = await captain.updateFAQ(req.params.id, req.body);
    if (!faq) return res.status(404).json({ error: "FAQ not found" });
    res.json({ success: true, faq });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.delete("/products/api/captain/faqs/:id", requireAuth, async (req, res) => {
  try {
    const ok = await captain.deleteFAQ(req.params.id);
    res.json({ success: ok });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── Tools (read-only) ───
app.get("/products/api/captain/tools", requireAuth, async (req, res) => {
  try {
    const tools = await captain.listTools();
    res.json({ tools });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── Assistant config (instructions/system prompt) ───
app.get("/products/api/captain/assistant", requireAuth, async (req, res) => {
  try {
    const a = await captain.getAssistant();
    res.json({ assistant: a });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.put("/products/api/captain/assistant/instructions", requireAuth, async (req, res) => {
  try {
    const { instructions } = req.body;
    if (!instructions) return res.status(400).json({ error: "instructions required" });
    const cfg = await captain.updateAssistantInstructions(instructions);
    res.json({ success: true, config: cfg });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// ─── Smart helper: AI-suggested FAQs from a document ───
// Uses simple heuristics (no LLM call yet - to be added later)
app.get("/products/api/captain/documents/:id/suggested-faqs", requireAuth, async (req, res) => {
  try {
    const doc = await captain.getDocument(req.params.id);
    if (!doc) return res.status(404).json({ error: "Not found" });

    // Naive: split content into Q&A pairs based on "؟" markers
    const content = doc.content || '';
    const sentences = content.split(/\n\n+|\.\s+/).map(s => s.trim()).filter(s => s.length > 30);
    const questions = sentences.filter(s => s.includes('؟') || s.includes('?')).slice(0, 10);

    res.json({
      suggestions: questions.map(q => ({
        question: q.slice(0, 200),
        suggested_answer: "(يحتاج تحرير من الموظف)",
        source_document_id: doc.id
      })),
      note: "هذه اقتراحات أولية. سيتم إضافة AI suggestions في Phase 5."
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});


// ─── QA Audit Dashboard (review customer service quality) ───
app.get("/products/qa-audit", requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, "public", "qa-audit", "index.html"));
});


app.listen(PORT, '127.0.0.1', async () => {
  console.log(`✅ QAYDAO Master Catalog on http://127.0.0.1:${PORT}/products`);
  try {
    const { rows: [r] } = await db.query('SELECT COUNT(*) AS n FROM master_products WHERE deleted_at IS NULL');
    console.log(`   Master Products: ${r.n}`);
    const studioStats = await adapters.studio.getStats();
    console.log(`   Studio: ${studioStats.total}`);
    const salesStats = await adapters.sales.getStats();
    console.log(`   Sales: ${salesStats.total}`);
  } catch (err) {
    console.error('Boot stats error:', err.message);
  }
});
