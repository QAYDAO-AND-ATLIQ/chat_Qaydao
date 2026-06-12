#!/usr/bin/env node
/**
 * QAYDAO Captain — Failure Extractor (vacation-safe learning source)
 * ==================================================================
 * The normal learning extractor mines HUMAN agent replies. During the team's
 * vacation there are no human replies, so this script provides the alternative
 * learning source: it mines questions where Captain FAILED (said "للأسف /
 * لم أتمكن / لم أجد" or handed off) WITHOUT a human reply, and asks GPT-4o-mini
 * to propose a correct, reusable FAQ answer using QAYDAO store knowledge.
 *
 * Output: pending rows in captain_learning_suggestions for Rami to review at
 *         /products/captain/learn (agent_name = "اقتراح AI - فجوة معرفية").
 *
 * Usage:
 *   node scripts/extract_failures.js [--days 3] [--limit 50] [--dry-run]
 */
require("dotenv").config();
const { Pool } = require("pg");
const OpenAI = require("openai");

const argv = process.argv.slice(2);
const DAYS = parseInt(argv[argv.indexOf("--days") + 1]) || 3;
const LIMIT = parseInt(argv[argv.indexOf("--limit") + 1]) || 50;
const DRY_RUN = argv.includes("--dry-run");

const chatwootPool = new Pool({
  host: "127.0.0.1", port: 5437, database: "chatwoot_production",
  user: "chatwoot_user", password: "f5c0e58555c94b08befed4db5643cb89d549983e9d9e132d",
});
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

function log(m) {
  const ts = new Date().toISOString().replace("T", " ").slice(0, 19);
  console.log(`${ts} [failure-extractor] ${m}`);
}

// Find customer questions that Captain answered with a failure phrase (no human reply after)
async function findFailures() {
  log(`scanning last ${DAYS} days for Captain failures (no human reply)`);
  const { rows } = await chatwootPool.query(`
    WITH fail_replies AS (
      SELECT m.id AS fail_id, m.conversation_id, m.inbox_id, m.created_at
      FROM messages m
      WHERE m.sender_type = 'Captain::Assistant'
        AND (m.private = false OR m.private IS NULL)
        AND m.created_at > NOW() - ($1 || ' days')::interval
        AND (
          m.content ILIKE '%للأسف%' OR m.content ILIKE '%لم أتمكن%'
          OR m.content ILIKE '%لم أجد%' OR m.content ILIKE '%لا يمكنني%'
          OR m.content ILIKE '%لم أعثر%'
        )
        -- exclude order-not-found escalations (handled separately)
        AND m.content NOT LIKE '%تم رفع طلبك لخدمة العملاء%'
    )
    SELECT
      fr.conversation_id AS conv_id,
      i.channel_type,
      (SELECT m2.content FROM messages m2
       WHERE m2.conversation_id = fr.conversation_id
         AND m2.message_type = 0 AND m2.id < fr.fail_id
         AND LENGTH(m2.content) > 8
       ORDER BY m2.id DESC LIMIT 1) AS customer_question
    FROM fail_replies fr
    JOIN inboxes i ON i.id = fr.inbox_id
    -- no human agent reply in this conversation
    WHERE NOT EXISTS (
      SELECT 1 FROM messages mu
      WHERE mu.conversation_id = fr.conversation_id
        AND mu.sender_type = 'User' AND mu.message_type = 1 AND mu.private = false
    )
    AND NOT EXISTS (
      SELECT 1 FROM captain_learning_suggestions cls
      WHERE cls.conversation_id = fr.conversation_id
    )
    LIMIT $2
  `, [DAYS, LIMIT]);
  const valid = rows.filter(r => r.customer_question && r.customer_question.trim().length > 8);
  log(`found ${valid.length} failure questions worth proposing FAQs for`);
  return valid;
}

const SYSTEM_PROMPT = `أنت خبير خدمة عملاء لمتجر كواي داو (qaydao.com)، متجر أثاث سعودي فاخر. واجه المساعد الآلي سؤالاً ولم يستطع الإجابة. مهمتك اقتراح إجابة احترافية صحيحة يمكن إضافتها كـ FAQ.

معلومات المتجر المؤكدة:
- خدمة العملاء: 966548456966+ | info@qaydao.com | الأحد-الخميس 9ص-6م
- الشحن مجاني فوق 700 ريال. التوصيل: جاهز 3-7 أيام، مصنوع حسب الطلب 30-60 يوم
- الدفع: مدى، فيزا، Apple Pay، تابي، تمارا
- الإرجاع: خلال 24 ساعة من الاستلام (خلل مصنعي). الإلغاء: خلال 24 ساعة من التأكيد
- التركيب: غير متوفر حالياً. لا يوجد معرض فعلي للمعاينة
- التتبع: track.qaydao.com

أنتج JSON:
{
  "should_learn": true/false,
  "reasoning": "السبب بالعربية",
  "suggested_question": "صياغة عامة للسؤال",
  "suggested_answer": "إجابة احترافية موجزة 2-4 أسطر، بدون إيموجي، بنبرة سعودية راقية"
}

should_learn = false إذا:
- السؤال خاص بطلب فردي أو شكوى شخصية
- السؤال غامض جداً أو مجرد تحية
- الإجابة تتطلب معلومات لا تملكها (لا تخترع أسعاراً أو تفاصيل منتجات محددة)
- السؤال يحتاج تدخل بشري (شكوى، استرجاع مبلغ، نزاع)

suggested_answer: لا تخترع معلومات. إن لم تكن متأكداً، اجعل الإجابة توجّه العميل لخدمة العملاء. بدون إيموجي إطلاقاً.`;

async function propose(question) {
  try {
    const res = await openai.chat.completions.create({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: `سؤال العميل الذي عجز المساعد عنه: ${question}` }
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

async function save(candidate, n) {
  if (!n) return;
  await chatwootPool.query(`
    INSERT INTO captain_learning_suggestions
      (conversation_id, channel_type, agent_name,
       original_question, original_agent_reply,
       suggested_question, suggested_answer, ai_reasoning, status)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
    ON CONFLICT (conversation_id, original_question) DO NOTHING
  `, [
    candidate.conv_id, candidate.channel_type, "اقتراح AI - فجوة معرفية",
    candidate.customer_question.slice(0, 2000),
    "(لا يوجد رد موظف — اقتراح مبني على عجز المساعد)",
    n.suggested_question?.slice(0, 500),
    n.suggested_answer?.slice(0, 2000),
    n.reasoning?.slice(0, 500),
    n.should_learn ? "pending" : "rejected"
  ]);
}

async function main() {
  if (DRY_RUN) log("DRY RUN — no writes");
  if (!process.env.OPENAI_API_KEY) { log("OPENAI_API_KEY missing"); process.exit(1); }
  const cands = await findFailures();
  if (!cands.length) { log("no new failures"); await chatwootPool.end(); process.exit(0); }
  let learn = 0, rej = 0, err = 0;
  for (const c of cands) {
    try {
      const n = await propose(c.customer_question);
      if (!n) { err++; continue; }
      if (DRY_RUN) log(`[conv ${c.conv_id}] learn=${n.should_learn} Q="${(n.suggested_question||'').slice(0,40)}"`);
      else await save(c, n);
      n.should_learn ? learn++ : rej++;
    } catch (e) { log(`conv ${c.conv_id}: ${e.message}`); err++; }
  }
  log(`done. proposed=${learn} rejected=${rej} errors=${err}`);
  await chatwootPool.end();
  process.exit(0);
}
main().catch(e => { log(`FATAL: ${e.message}`); process.exit(1); });
