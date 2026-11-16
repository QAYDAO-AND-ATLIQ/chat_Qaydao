// QAYDAO — «مراجعة الكابتن اليومية» (2026-11-17، قرار رامي)
// كل موظف خدمة عملاء يحصل يومياً على دفعة صغيرة (~15 دقيقة) من ثلاثة أنواع:
//   reply      ← تصحيح ردود QAYDAO AI الفعلية (الأولوية للردود المشكوك فيها)
//   suggestion ← اقتراحات التعلّم المعلّقة (اعتماد/رفض)
//   faq        ← أسئلة شائعة معتمدة يستخدمها الـAI ولم يراجعها أحد
// الدفعة تُولَّد بطلب من فريقي (captain:daily-review)، وكل بند محجوز لموظف واحد،
// والإنجاز يُحسب من سجل التدقيق الفعلي (logAudit) لا من ضغطة «تم».
const db = require('./db-pg');
const captain = require('./captain-manager');

const cw = captain.pool;
const ASSISTANT_ID = 1;
const TZ = 'Asia/Riyadh';
const TYPES = ['reply', 'suggestion', 'faq'];
const DEFAULT_QUOTA = { reply: 4, suggestion: 2, faq: 2 };
const REPLY_WINDOW_DAYS = 3; // يغطي الجمعة والسبت
const MAX_PER_PERSON = 12;

// خريطة إجراءات سجل التدقيق ← نتيجة البند
const ACTION_OUTCOME = {
  'reply.ok': ['reply', 'ok'],
  'captain.teach': ['reply', 'corrected'],
  'learn.approve': ['suggestion', 'approved'],
  'learn.reject': ['suggestion', 'rejected'],
  'faq.review': ['faq', 'reviewed'],
  'faq.update': ['faq', 'corrected'],
  'faq.delete': ['faq', 'deleted'],
};
// نتيجة أقوى تحلّ محل أضعف (مثلاً: صحّح ثم وسم مراجَع ⇒ تبقى «صُحّح»)
const OUTCOME_RANK = { ok: 1, reviewed: 1, rejected: 2, approved: 2, corrected: 3, deleted: 3 };

let schemaReady = null;
function ensureSchema() {
  if (!schemaReady) {
    schemaReady = db.query(`
      CREATE TABLE IF NOT EXISTS captain_review_items (
        id            BIGSERIAL PRIMARY KEY,
        batch_date    DATE        NOT NULL,
        assignee_email TEXT       NOT NULL,
        assignee_name TEXT,
        item_type     TEXT        NOT NULL CHECK (item_type IN ('reply','suggestion','faq')),
        ref_id        BIGINT      NOT NULL,
        conversation_id BIGINT,
        priority      INT         NOT NULL DEFAULT 0,
        reason        TEXT,
        status        TEXT        NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','expired')),
        outcome       TEXT,
        done_by_email TEXT,
        done_by_name  TEXT,
        done_at       TIMESTAMPTZ,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
      CREATE UNIQUE INDEX IF NOT EXISTS captain_review_items_live_ref
        ON captain_review_items (item_type, ref_id) WHERE status <> 'expired';
      CREATE INDEX IF NOT EXISTS captain_review_items_batch
        ON captain_review_items (batch_date, assignee_email);
    `).catch(e => { schemaReady = null; throw e; });
  }
  return schemaReady;
}

function riyadhToday() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date());
}
function cleanDate(d) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(d || '')) ? String(d) : riyadhToday();
}
function normEmail(e) { return String(e || '').trim().toLowerCase(); }

// ── المرشحون من قاعدة الشات ─────────────────────────────────────────

async function liveRefs(type) {
  const { rows } = await db.query(
    `SELECT ref_id FROM captain_review_items WHERE item_type = $1 AND status <> 'expired'`, [type]);
  return rows.map(r => Number(r.ref_id));
}

// ردود الـAI في الأيام الثلاثة السابقة للدفعة، مرتبة بالشك: رد بالإنجليزية أو صورة مكسورة،
// تقييم عميل منخفض، تدخل موظف بعد الرد (الـAI لم يحسم)، تكرار نفس الرد في المحادثة.
// رد واحد لكل محادثة، ويُستبعد ما حُجز سابقاً.
async function replyCandidates(batchDate, limit) {
  const exclude = await liveRefs('reply');
  const { rows } = await cw.query(`
    WITH win AS (
      SELECT (($1::date - $2::int)::timestamp AT TIME ZONE '${TZ}') AS t0,
             ($1::date::timestamp AT TIME ZONE '${TZ}')              AS t1
    ),
    cm AS (
      SELECT m.id, m.conversation_id, m.content, m.created_at
      FROM messages m, win
      WHERE m.sender_type = 'Captain::Assistant'
        AND m.created_at >= win.t0 AT TIME ZONE 'UTC' AND m.created_at < win.t1 AT TIME ZONE 'UTC'
        AND (m.private = false OR m.private IS NULL)
        AND m.content NOT LIKE 'Auto-handoff:%'
        AND m.content NOT LIKE '%إنهاء هذه المحادثة%'
        AND LENGTH(TRIM(m.content)) > 15
        AND NOT (m.id = ANY($3::bigint[]))
        AND EXISTS (SELECT 1 FROM captain_inboxes ci
                    WHERE ci.inbox_id = m.inbox_id AND ci.captain_assistant_id = ${ASSISTANT_ID})
    ),
    scored AS (
      SELECT cm.*,
        (cm.content ILIKE '%unfortunately%' OR cm.content ILIKE '%I apologize%'
          OR cm.content ILIKE '%I cannot%' OR cm.content LIKE '%![%') AS f_format,
        EXISTS (SELECT 1 FROM csat_survey_responses s
                WHERE s.conversation_id = cm.conversation_id AND s.rating <= 2) AS f_csat,
        EXISTS (SELECT 1 FROM messages h
                WHERE h.conversation_id = cm.conversation_id AND h.id > cm.id
                  AND h.message_type = 1 AND h.sender_type = 'User'
                  AND (h.private = false OR h.private IS NULL)) AS f_handoff,
        EXISTS (SELECT 1 FROM messages d
                WHERE d.conversation_id = cm.conversation_id AND d.id <> cm.id
                  AND d.sender_type = 'Captain::Assistant' AND d.content = cm.content) AS f_repeat,
        (SELECT m2.content FROM messages m2
          WHERE m2.conversation_id = cm.conversation_id AND m2.message_type = 0 AND m2.id < cm.id
          ORDER BY m2.id DESC LIMIT 1) AS customer_question
      FROM cm
    ),
    ranked AS (
      SELECT DISTINCT ON (conversation_id) *,
        (CASE WHEN f_format THEN 5 ELSE 0 END + CASE WHEN f_csat THEN 4 ELSE 0 END
         + CASE WHEN f_handoff THEN 3 ELSE 0 END + CASE WHEN f_repeat THEN 3 ELSE 0 END) AS score
      FROM scored
      WHERE customer_question IS NOT NULL AND LENGTH(TRIM(customer_question)) > 1
      ORDER BY conversation_id, (CASE WHEN f_format THEN 5 ELSE 0 END + CASE WHEN f_csat THEN 4 ELSE 0 END
         + CASE WHEN f_handoff THEN 3 ELSE 0 END + CASE WHEN f_repeat THEN 3 ELSE 0 END) DESC, id DESC
    )
    SELECT id, conversation_id, score, f_format, f_csat, f_handoff, f_repeat
    FROM ranked ORDER BY score DESC, random() LIMIT $4
  `, [batchDate, REPLY_WINDOW_DAYS, exclude, limit]);
  return rows.map(r => {
    const why = [];
    if (r.f_format) why.push('صياغة أو لغة غير سليمة');
    if (r.f_csat) why.push('تقييم العميل منخفض');
    if (r.f_handoff) why.push('تدخّل موظف بعد الرد');
    if (r.f_repeat) why.push('الرد تكرر في المحادثة');
    return { ref_id: Number(r.id), conversation_id: Number(r.conversation_id), priority: Number(r.score),
             reason: why.length ? why.join('، ') : 'عيّنة عشوائية للتأكد من الجودة' };
  });
}

async function suggestionCandidates(limit) {
  const exclude = await liveRefs('suggestion');
  const { rows } = await cw.query(`
    SELECT id, conversation_id FROM captain_learning_suggestions
    WHERE status = 'pending' AND assistant_id = ${ASSISTANT_ID} AND NOT (id = ANY($1::bigint[]))
    ORDER BY created_at DESC LIMIT $2`, [exclude, limit]);
  return rows.map(r => ({ ref_id: Number(r.id), conversation_id: Number(r.conversation_id), priority: 1,
                          reason: 'اقتراح تعلّم من ردّ موظف — بانتظار القرار' }));
}

async function faqCandidates(limit) {
  const exclude = await liveRefs('faq');
  const { rows } = await cw.query(`
    SELECT id FROM captain_assistant_responses
    WHERE assistant_id = ${ASSISTANT_ID} AND status = 1 AND (reviewed IS NOT TRUE)
      AND NOT (id = ANY($1::bigint[]))
    ORDER BY updated_at DESC LIMIT $2`, [exclude, limit]);
  return rows.map(r => ({ ref_id: Number(r.id), conversation_id: null, priority: 0,
                          reason: 'إجابة يستخدمها الـAI حالياً ولم يراجعها أحد' }));
}

// ── التوليد ─────────────────────────────────────────────────────────

async function generate({ date, reviewers, quota } = {}) {
  await ensureSchema();
  const batchDate = cleanDate(date);
  const people = (reviewers || [])
    .map(r => ({ email: normEmail(r.email), name: String(r.name || '').trim() || null }))
    .filter(r => r.email);
  if (!people.length) throw new Error('reviewers required');
  const q = { ...DEFAULT_QUOTA };
  for (const t of TYPES) {
    const v = parseInt(quota && quota[t]);
    if (Number.isFinite(v) && v >= 0) q[t] = Math.min(v, MAX_PER_PERSON);
  }

  // البنود المفتوحة من أيام سابقة تنتهي (تعود للمرشحين) — لا تتراكم على الموظف
  await db.query(
    `UPDATE captain_review_items SET status = 'expired' WHERE status = 'open' AND batch_date < $1`, [batchDate]);

  const { rows: existing } = await db.query(
    `SELECT assignee_email, COUNT(*)::int AS n FROM captain_review_items
     WHERE batch_date = $1 AND status <> 'expired' GROUP BY 1`, [batchDate]);
  const have = new Set(existing.map(r => r.assignee_email));
  const fresh = people.filter(p => !have.has(p.email));

  if (fresh.length) {
    const n = fresh.length;
    const total = q.reply + q.suggestion + q.faq;
    const pools = {
      reply: await replyCandidates(batchDate, (q.reply + total) * n),
      suggestion: await suggestionCandidates((q.suggestion + total) * n),
      faq: await faqCandidates((q.faq + total) * n),
    };
    const plan = new Map(fresh.map(p => [p.email, []]));
    // توزيع دائري عادل لكل نوع: الأعلى أولوية يتوزع على الجميع لا على أولهم
    for (const t of TYPES) {
      for (let k = 0; k < q[t]; k++) {
        for (const p of fresh) {
          const it = pools[t].shift();
          if (it) plan.get(p.email).push({ ...it, item_type: t });
        }
      }
    }
    // نقص نوع ⇒ يُكمل من الأنواع الأخرى حتى تبلغ الدفعة حجمها
    for (const p of fresh) {
      const list = plan.get(p.email);
      for (const t of ['reply', 'faq', 'suggestion']) {
        while (list.length < total && pools[t].length) list.push({ ...pools[t].shift(), item_type: t });
      }
    }
    await db.tx(async (c) => {
      for (const p of fresh) {
        for (const it of plan.get(p.email)) {
          await c.query(`
            INSERT INTO captain_review_items
              (batch_date, assignee_email, assignee_name, item_type, ref_id, conversation_id, priority, reason)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
            ON CONFLICT DO NOTHING`,
            [batchDate, p.email, p.name, it.item_type, it.ref_id, it.conversation_id, it.priority, it.reason]);
        }
      }
    });
  }
  return status({ date: batchDate, emails: people.map(p => p.email) });
}

// ── الحالة (لفريقي والتقارير) ───────────────────────────────────────

async function status({ date, from, to, emails } = {}) {
  await ensureSchema();
  const d0 = from ? cleanDate(from) : cleanDate(date);
  const d1 = to ? cleanDate(to) : d0;
  const params = [d0, d1];
  let f = '';
  if (emails && emails.length) { params.push(emails.map(normEmail)); f = 'AND assignee_email = ANY($3)'; }
  const { rows } = await db.query(`
    SELECT assignee_email AS email, MAX(assignee_name) AS name,
      COUNT(*) FILTER (WHERE status <> 'expired')::int                         AS total,
      COUNT(*) FILTER (WHERE status = 'done')::int                             AS done,
      COUNT(*) FILTER (WHERE status = 'done' AND done_by_email = assignee_email)::int AS done_self,
      COUNT(*) FILTER (WHERE status = 'expired')::int                          AS expired,
      COUNT(*) FILTER (WHERE outcome = 'corrected')::int                       AS corrected,
      COUNT(*) FILTER (WHERE outcome IN ('ok','reviewed'))::int                AS confirmed,
      COUNT(*) FILTER (WHERE outcome = 'approved')::int                        AS approved,
      COUNT(*) FILTER (WHERE outcome IN ('rejected','deleted'))::int           AS rejected,
      COUNT(*) FILTER (WHERE item_type = 'reply' AND status <> 'expired')::int      AS replies,
      COUNT(*) FILTER (WHERE item_type = 'suggestion' AND status <> 'expired')::int AS suggestions,
      COUNT(*) FILTER (WHERE item_type = 'faq' AND status <> 'expired')::int        AS faqs,
      COUNT(DISTINCT batch_date)::int                                          AS days,
      MAX(done_at)                                                             AS last_done_at
    FROM captain_review_items
    WHERE batch_date BETWEEN $1 AND $2 ${f}
    GROUP BY assignee_email ORDER BY assignee_email`, params);
  return { from: d0, to: d1, people: rows };
}

// ── دفعة الموظف (لصفحة «مراجعتي اليوم») ─────────────────────────────

async function mine({ email, date } = {}) {
  await ensureSchema();
  const batchDate = cleanDate(date);
  const { rows: items } = await db.query(`
    SELECT id, batch_date, item_type, ref_id, conversation_id, priority, reason, status, outcome,
           done_by_name, done_by_email, done_at
    FROM captain_review_items
    WHERE batch_date = $1 AND assignee_email = $2 AND status <> 'expired'
    ORDER BY CASE item_type WHEN 'reply' THEN 1 WHEN 'suggestion' THEN 2 ELSE 3 END, priority DESC, id`,
    [batchDate, normEmail(email)]);
  const ids = t => items.filter(i => i.item_type === t).map(i => Number(i.ref_id));

  const [replies, sugs, faqs] = await Promise.all([
    ids('reply').length ? cw.query(`
      SELECT m.id, m.conversation_id, m.content AS reply, m.created_at AS reply_at, i.name AS inbox,
        (SELECT m2.content FROM messages m2 WHERE m2.conversation_id = m.conversation_id
           AND m2.message_type = 0 AND m2.id < m.id ORDER BY m2.id DESC LIMIT 1) AS question
      FROM messages m JOIN inboxes i ON i.id = m.inbox_id WHERE m.id = ANY($1)`, [ids('reply')]) : { rows: [] },
    ids('suggestion').length ? cw.query(`
      SELECT id, conversation_id, original_question, original_agent_reply, agent_name,
             suggested_question, suggested_answer, ai_reasoning, status
      FROM captain_learning_suggestions WHERE id = ANY($1)`, [ids('suggestion')]) : { rows: [] },
    ids('faq').length ? cw.query(`
      SELECT id, question, answer, reviewed, updated_at FROM captain_assistant_responses
      WHERE id = ANY($1)`, [ids('faq')]) : { rows: [] },
  ]);
  const by = rows => new Map(rows.map(r => [Number(r.id), r]));
  const maps = { reply: by(replies.rows), suggestion: by(sugs.rows), faq: by(faqs.rows) };

  const out = items.map(i => ({ ...i, id: Number(i.id), ref_id: Number(i.ref_id),
                                detail: maps[i.item_type].get(Number(i.ref_id)) || null }));
  const done = out.filter(i => i.status === 'done').length;
  return { date: batchDate, total: out.length, done, items: out };
}

async function getItem(id) {
  await ensureSchema();
  const { rows } = await db.query(`SELECT * FROM captain_review_items WHERE id = $1`, [id]);
  return rows[0] || null;
}

// ── الإغلاق من سجل التدقيق ──────────────────────────────────────────
// يُستدعى من logAudit بعد كل إجراء حقيقي. يغلق البند المحجوز لهذا المرجع (لأي موظف كان)
// ويسجّل من أنجزه فعلاً — فلا تُنسب مراجعة لغير صاحبها.
async function markFromAudit(actor, action, targetType, targetId) {
  const map = ACTION_OUTCOME[action];
  if (!map || targetId == null) return null;
  const [type, outcome] = map;
  if (type !== targetType) return null;
  await ensureSchema();
  const a = actor || {};
  const { rows: [cur] } = await db.query(
    `SELECT id, status, outcome FROM captain_review_items
     WHERE item_type = $1 AND ref_id = $2 AND status <> 'expired'`, [type, Number(targetId)]);
  if (!cur) return null;
  const keep = cur.status === 'done' && (OUTCOME_RANK[cur.outcome] || 0) > (OUTCOME_RANK[outcome] || 0);
  const { rows } = await db.query(`
    UPDATE captain_review_items SET
      status = 'done',
      outcome = $2,
      done_by_email = COALESCE(done_by_email, $3),
      done_by_name  = COALESCE(done_by_name, $4),
      done_at       = COALESCE(done_at, NOW())
    WHERE id = $1
    RETURNING id, status, outcome`,
    [cur.id, keep ? cur.outcome : outcome, normEmail(a.email) || null, a.name || null]);
  return rows[0] || null;
}

module.exports = { ensureSchema, generate, status, mine, getItem, markFromAudit, riyadhToday,
                   ACTION_OUTCOME, OUTCOME_RANK, DEFAULT_QUOTA };
