#!/usr/bin/env node
/**
 * QAYDAO Captain — Learning Extractor
 * ====================================
 * Mines conversations where Captain failed and a human agent stepped in.
 * For each (customer question → agent reply) pair, uses GPT-4o-mini to:
 *   1. Normalize the question (generalize, remove personal info)
 *   2. Polish the answer (clean, professional, reusable)
 *   3. Decide if this Q&A is worth learning from
 *
 * Output: rows in captain_learning_suggestions ready for human review.
 *
 * Usage:
 *   node /root/qaydao-products/scripts/extract_learning_suggestions.js
 *   node /root/qaydao-products/scripts/extract_learning_suggestions.js --days 14 --limit 100
 *
 * Cron (daily at 3am):
 *   0 3 * * * cd /root/qaydao-products && /usr/bin/node scripts/extract_learning_suggestions.js >> logs/learning.log 2>&1
 */

require("dotenv").config();
const { Pool } = require("pg");
const OpenAI = require("openai");

const argv = process.argv.slice(2);
const DAYS = parseInt(argv[argv.indexOf("--days") + 1]) || 7;
const LIMIT = parseInt(argv[argv.indexOf("--limit") + 1]) || 50;
const DRY_RUN = argv.includes("--dry-run");

const chatwootPool = new Pool({
  host: "127.0.0.1",
  port: 5437,
  database: "chatwoot_production",
  user: "chatwoot_user",
  password: "f5c0e58555c94b08befed4db5643cb89d549983e9d9e132d",
});

// Use the same OpenAI key Captain uses
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

function log(msg) {
  const ts = new Date().toISOString().replace("T", " ").slice(0, 19);
  console.log(`${ts} [learning-extractor] ${msg}`);
}

// ──────────────── 1. Find candidate Q&A pairs ────────────────
async function findCandidates() {
  log(`scanning last ${DAYS} days for Captain-failed conversations`);
  const { rows } = await chatwootPool.query(`
    WITH candidate_convs AS (
      SELECT c.id AS conv_id, c.contact_id, c.inbox_id
      FROM conversations c
      WHERE c.created_at > NOW() - ($1 || ' days')::interval
        AND EXISTS (
          SELECT 1 FROM messages m1 
          WHERE m1.conversation_id = c.id AND m1.sender_type = 'Captain::Assistant'
        )
        AND EXISTS (
          SELECT 1 FROM messages m2
          WHERE m2.conversation_id = c.id 
            AND m2.sender_type = 'User' 
            AND m2.message_type = 1 
            AND m2.private = false
            AND LENGTH(m2.content) > 20
        )
    )
    SELECT
      cc.conv_id,
      i.channel_type,
      (SELECT m.content FROM messages m
       WHERE m.conversation_id = cc.conv_id
         AND m.message_type = 0
         AND LENGTH(m.content) > 5
       ORDER BY m.id LIMIT 1) AS customer_question,
      (SELECT m.content FROM messages m
       WHERE m.conversation_id = cc.conv_id
         AND m.sender_type = 'User'
         AND m.message_type = 1
         AND m.private = false
         AND LENGTH(m.content) > 20
       ORDER BY m.id LIMIT 1) AS agent_reply,
      (SELECT u.name FROM messages m
       JOIN users u ON u.id = m.sender_id
       WHERE m.conversation_id = cc.conv_id
         AND m.sender_type = 'User'
         AND m.message_type = 1
       ORDER BY m.id LIMIT 1) AS agent_name
    FROM candidate_convs cc
    JOIN inboxes i ON i.id = cc.inbox_id
    WHERE NOT EXISTS (
      SELECT 1 FROM captain_learning_suggestions cls
      WHERE cls.conversation_id = cc.conv_id
    )
    LIMIT $2
  `, [DAYS, LIMIT]);
  log(`found ${rows.length} new candidate conversations`);
  return rows.filter(r => r.customer_question && r.agent_reply);
}

// ──────────────── 2. AI normalization ────────────────
const SYSTEM_PROMPT = `أنت محلل بيانات لشركة كواي داو (متجر أثاث سعودي). مهمتك تحويل محادثة عميل-موظف إلى FAQ احترافي قابل للإعادة الاستخدام.

ستحصل على:
- سؤال العميل الأصلي (قد يحتوي على معلومات شخصية، أرقام طلبات، ركاكة)
- رد الموظف الفعلي (قد يحتوي على تحية، توقيع، تفاصيل خاصة بهذا العميل)

مهمتك أن تنتج JSON بهذا الشكل:
{
  "should_learn": true/false,
  "reasoning": "سبب القرار بالعربية",
  "suggested_question": "صياغة عامة للسؤال يمكن لأي عميل استخدامها",
  "suggested_answer": "إجابة احترافية موجزة (2-4 أسطر) بدون معلومات شخصية، بدون تحية، بدون توقيع"
}

قواعد should_learn = false:
- الرد متعلق بمشكلة فردية محددة (طلب معين، شكوى شخصية)
- الرد يطلب معلومات من العميل (مثل: ابعت رقم طلبك)
- السؤال غامض (مثل: السلام عليكم فقط)
- رد الموظف مجرد تحية (أهلا، معك فلان)
- رد الموظف يحول لقناة أخرى

قواعد suggested_question:
- اجعله سؤال عام (مثلاً "كم رقم طلبي" → "كيف أعرف رقم طلبي؟")
- بالعربية الفصحى المبسطة
- اطرحه كما يطرحه العميل (أنا، أنت، لي، عندكم)
- لا تنسخ السؤال الأصلي حرفياً إن كان فيه أسماء أو أرقام

قواعد suggested_answer:
- 2-4 أسطر فقط
- بدون "عزيزي العميل" أو "أهلا"
- بدون توقيع الموظف
- استبدل التفاصيل الخاصة (أرقام، أسماء) بمعلومات عامة
- نبرة احترافية ودودة سعودية`;

async function normalize(customer_question, agent_reply) {
  try {
    const res = await openai.chat.completions.create({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: `سؤال العميل: ${customer_question}\n\nرد الموظف: ${agent_reply}` }
      ],
      response_format: { type: "json_object" },
      temperature: 0.3,
    });
    return JSON.parse(res.choices[0].message.content);
  } catch (err) {
    log(`OpenAI error: ${err.message}`);
    return null;
  }
}

// ──────────────── 3. Save suggestions ────────────────
async function saveSuggestion(candidate, normalized) {
  if (!normalized) return false;
  
  await chatwootPool.query(`
    INSERT INTO captain_learning_suggestions
      (conversation_id, channel_type, agent_name,
       original_question, original_agent_reply,
       suggested_question, suggested_answer, ai_reasoning,
       status)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (conversation_id, original_question) DO NOTHING
  `, [
    candidate.conv_id,
    candidate.channel_type,
    candidate.agent_name,
    candidate.customer_question.slice(0, 2000),
    candidate.agent_reply.slice(0, 4000),
    normalized.suggested_question?.slice(0, 500),
    normalized.suggested_answer?.slice(0, 2000),
    normalized.reasoning?.slice(0, 500),
    normalized.should_learn ? "pending" : "rejected"
  ]);
  return true;
}

// ──────────────── Main ────────────────
async function main() {
  if (DRY_RUN) log("🧪 DRY RUN — no DB writes");
  if (!process.env.OPENAI_API_KEY) {
    log("⚠ OPENAI_API_KEY not set — exiting");
    process.exit(1);
  }
  
  const candidates = await findCandidates();
  if (candidates.length === 0) {
    log("✓ no new candidates");
    process.exit(0);
  }
  
  let learned = 0, rejected = 0, errors = 0;
  for (const c of candidates) {
    try {
      const normalized = await normalize(c.customer_question, c.agent_reply);
      if (!normalized) { errors++; continue; }
      
      if (DRY_RUN) {
        log(`[conv ${c.conv_id}] learn=${normalized.should_learn} Q="${normalized.suggested_question?.slice(0, 50)}"`);
      } else {
        await saveSuggestion(c, normalized);
      }
      
      if (normalized.should_learn) learned++;
      else rejected++;
    } catch (err) {
      log(`✗ conv ${c.conv_id}: ${err.message}`);
      errors++;
    }
  }
  
  log(`✓ done. learned=${learned} rejected=${rejected} errors=${errors}`);
  await chatwootPool.end();
  process.exit(0);
}

main().catch(err => {
  log(`✗ FATAL: ${err.message}`);
  console.error(err);
  process.exit(1);
});
