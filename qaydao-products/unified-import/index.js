// Unified Import — orchestrator
// =============================
// Takes a buffer + filename, parses it, then propagates to all 3 platforms.
// Does NOT delete anything. Skipped/missing products are simply ignored.
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");

const { parseSallaCsv } = require("./parsers/csv");
const { parseSallaXml } = require("./parsers/xml");
const masterProp = require("./propagators/master");
const salesProp = require("./propagators/sales");
const studioProp = require("./propagators/studio");

const db = require("../db-pg");

async function detectFormat(buffer, filename) {
  const head = buffer.slice(0, 200).toString("utf-8").trim();
  const ext = (filename || "").toLowerCase().split(".").pop();
  if (head.startsWith("<?xml") || head.startsWith("<rss")) return "xml";
  if (ext === "xml") return "xml";
  if (ext === "csv") return "csv";
  // Default: CSV
  return "csv";
}

async function runUnifiedImport({ buffer, filename, uploadedBy = "employee" }) {
  const startedAt = new Date();
  const startMs = Date.now();
  const result = {
    started_at: startedAt.toISOString(),
    filename,
    file_size: buffer.length,
    format: null,
    products_parsed: 0,
    master: null,
    sales: null,
    studio: null,
    duration_ms: 0,
    error: null,
  };

  let jobId = null;

  try {
    const fileSha = crypto.createHash("sha256").update(buffer).digest("hex");

    // Create job record
    try {
      const { rows: [job] } = await db.query(`
        INSERT INTO upload_jobs (filename, file_size, file_sha256, products_before, status, uploaded_by, source)
        VALUES ($1, $2, $3, 0, 'processing', $4, 'unified')
        RETURNING id
      `, [filename, buffer.length, fileSha, uploadedBy]);
      jobId = job.id;
    } catch (err) {
      // upload_jobs table may have different schema — non-fatal
      console.warn("[unified] could not create job record:", err.message);
    }

    // Detect format
    result.format = await detectFormat(buffer, filename);

    // Parse
    let products;
    if (result.format === "xml") {
      products = parseSallaXml(buffer);
    } else {
      products = await parseSallaCsv(buffer);
    }
    result.products_parsed = products.length;

    if (products.length === 0) {
      throw new Error("لم يتم العثور على منتجات في الملف");
    }

    // Propagate to all 3 in parallel
    // (each propagator opens its own DB connection / sqlite handle)
    const [master, sales, studio] = await Promise.all([
      masterProp.propagate(products),
      salesProp.propagate(products),
      studioProp.propagate(products),
    ]);

    result.master = master;
    result.sales = sales;
    result.studio = studio;
    result.duration_ms = Date.now() - startMs;

    // Update job
    if (jobId) {
      try {
        await db.query(
          "UPDATE upload_jobs SET status = $1, completed_at = NOW(), products_added = $2, products_updated = $3 WHERE id = $4",
          ["completed", master.added, master.updated, jobId]
        );
      } catch (err) {
        console.warn("[unified] could not update job:", err.message);
      }
    }

    return result;
  } catch (err) {
    result.error = err.message;
    result.duration_ms = Date.now() - startMs;
    if (jobId) {
      try {
        await db.query(
          "UPDATE upload_jobs SET status = $1, completed_at = NOW(), error_message = $2 WHERE id = $3",
          ["failed", err.message.slice(0, 500), jobId]
        );
      } catch (e) { /* ignore */ }
    }
    throw err;
  }
}

module.exports = { runUnifiedImport };
