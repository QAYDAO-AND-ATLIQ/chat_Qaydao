// QAYDAO Captain Manager
// Connects to Chatwoot PostgreSQL to manage Captain AI documents, FAQs, scenarios
const { Pool } = require('pg');

const chatwootPool = new Pool({
  host: process.env.CHATWOOT_PG_HOST || '127.0.0.1',
  port: parseInt(process.env.CHATWOOT_PG_PORT) || 5437,
  database: process.env.CHATWOOT_PG_DB || 'chatwoot_production',
  user: process.env.CHATWOOT_PG_USER || 'chatwoot_user',
  password: process.env.CHATWOOT_PG_PASSWORD || 'f5c0e58555c94b08befed4db5643cb89d549983e9d9e132d',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000
});

const ACCOUNT_ID = 1;
const ASSISTANT_ID = 1;

chatwootPool.on('error', err => console.error('[Chatwoot PG]', err.message));

// ────────────────────────────────────────────────────────────
//  EMBEDDING GENERATOR (OpenAI text-embedding-3-small, 1536d)
// ────────────────────────────────────────────────────────────
async function generateEmbedding(text) {
  const OpenAI = require('openai');
  const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const r = await client.embeddings.create({
    model: 'text-embedding-3-small',
    input: text,
    encoding_format: 'float'
  });
  return r.data[0].embedding;
}

function vectorLiteral(arr) {
  // pgvector accepts string literal like "[0.1,0.2,...]"
  return '[' + arr.join(',') + ']';
}


// ────────────────────────────────────────────────────────────
//  DOCUMENTS
// ────────────────────────────────────────────────────────────

async function listDocuments() {
  const { rows } = await chatwootPool.query(`
    SELECT id, name, external_link, content, status, sync_status,
           created_at, updated_at, last_synced_at,
           LENGTH(content) AS content_length
    FROM captain_documents
    WHERE assistant_id = $1
    ORDER BY id
  `, [ASSISTANT_ID]);

  return rows.map(d => ({
    id: d.id,
    name: d.name,
    external_link: d.external_link,
    content: d.content,
    content_length: d.content_length,
    status: d.status,
    status_label: { 0: 'في الانتظار', 1: 'متاح', 2: 'فشل', 3: 'in_progress' }[d.status] || 'غير معروف',
    sync_status: d.sync_status,
    created_at: d.created_at,
    updated_at: d.updated_at,
    last_synced_at: d.last_synced_at
  }));
}

async function getDocument(id) {
  const { rows } = await chatwootPool.query(`
    SELECT * FROM captain_documents WHERE id = $1 AND assistant_id = $2
  `, [id, ASSISTANT_ID]);
  return rows[0] || null;
}

async function createDocument({ name, external_link, content }) {
  if (!name || !external_link) throw new Error('name and external_link are required');

  // Generate a unique external_link if user only provided a name
  const finalLink = external_link.startsWith('http')
    ? external_link
    : `https://qaydao.com/internal/${external_link.replace(/[^a-z0-9-_]/gi, '-')}`;

  const { rows } = await chatwootPool.query(`
    INSERT INTO captain_documents (name, external_link, content, status, sync_status, assistant_id, account_id, created_at, updated_at)
    VALUES ($1, $2, $3, 1, 0, $4, $5, NOW(), NOW())
    ON CONFLICT (assistant_id, external_link) DO UPDATE
    SET name = EXCLUDED.name, content = EXCLUDED.content, updated_at = NOW(), status = 1
    RETURNING *
  `, [name, finalLink, content || '', ASSISTANT_ID, ACCOUNT_ID]);

  return rows[0];
}

async function updateDocument(id, { name, content, external_link }) {
  // Only update fields that were provided
  const updates = [];
  const values = [];
  let idx = 1;

  if (name !== undefined) { updates.push(`name = $${idx++}`); values.push(name); }
  if (content !== undefined) { updates.push(`content = $${idx++}`); values.push(content); }
  if (external_link !== undefined) { updates.push(`external_link = $${idx++}`); values.push(external_link); }

  if (updates.length === 0) throw new Error('No fields to update');

  updates.push(`updated_at = NOW()`);
  updates.push(`status = 1`); // Mark as available after edit

  values.push(id);
  values.push(ASSISTANT_ID);

  const { rows } = await chatwootPool.query(`
    UPDATE captain_documents
    SET ${updates.join(', ')}
    WHERE id = $${idx++} AND assistant_id = $${idx}
    RETURNING *
  `, values);

  return rows[0];
}

async function deleteDocument(id) {
  const { rowCount } = await chatwootPool.query(`
    DELETE FROM captain_documents WHERE id = $1 AND assistant_id = $2
  `, [id, ASSISTANT_ID]);
  return rowCount > 0;
}

// ────────────────────────────────────────────────────────────
//  FAQ RESPONSES
// ────────────────────────────────────────────────────────────

async function listFAQs() {
  const { rows } = await chatwootPool.query(`
    SELECT id, question, answer, status, edited, documentable_id, documentable_type,
           created_at, updated_at
    FROM captain_assistant_responses
    WHERE assistant_id = $1
    ORDER BY id DESC
  `, [ASSISTANT_ID]);

  return rows.map(f => ({
    ...f,
    status_label: { 0: 'في الانتظار', 1: 'معتمد' }[f.status] || 'غير معروف'
  }));
}

async function createFAQ({ question, answer }) {
  if (!question || !answer) throw new Error('question and answer required');

  const { rows } = await chatwootPool.query(`
    INSERT INTO captain_assistant_responses
      (question, answer, status, edited, assistant_id, account_id, created_at, updated_at)
    VALUES ($1, $2, 1, TRUE, $3, $4, NOW(), NOW())
    RETURNING *
  `, [question, answer, ASSISTANT_ID, ACCOUNT_ID]);

  return rows[0];
}

async function updateFAQ(id, { question, answer, status }) {
  const updates = [];
  const values = [];
  let idx = 1;

  if (question !== undefined) { updates.push(`question = $${idx++}`); values.push(question); }
  if (answer !== undefined) { updates.push(`answer = $${idx++}`); values.push(answer); }
  if (status !== undefined) { updates.push(`status = $${idx++}`); values.push(status); }

  if (updates.length === 0) throw new Error('No fields to update');

  updates.push(`edited = TRUE`);
  updates.push(`updated_at = NOW()`);

  values.push(id);
  values.push(ASSISTANT_ID);

  const { rows } = await chatwootPool.query(`
    UPDATE captain_assistant_responses
    SET ${updates.join(', ')}
    WHERE id = $${idx++} AND assistant_id = $${idx}
    RETURNING *
  `, values);

  return rows[0];
}

async function deleteFAQ(id) {
  const { rowCount } = await chatwootPool.query(`
    DELETE FROM captain_assistant_responses WHERE id = $1 AND assistant_id = $2
  `, [id, ASSISTANT_ID]);
  return rowCount > 0;
}

// ────────────────────────────────────────────────────────────
//  CUSTOM TOOLS (read-only here - edit via Chatwoot)
// ────────────────────────────────────────────────────────────

async function listTools() {
  const { rows } = await chatwootPool.query(`
    SELECT id, slug, title, description, http_method, endpoint_url, enabled,
           created_at, updated_at
    FROM captain_custom_tools
    WHERE account_id = $1
    ORDER BY id
  `, [ACCOUNT_ID]);
  return rows;
}

// ────────────────────────────────────────────────────────────
//  ASSISTANT CONFIG
// ────────────────────────────────────────────────────────────

async function getAssistant() {
  const { rows } = await chatwootPool.query(`
    SELECT id, name, description, config FROM captain_assistants WHERE id = $1
  `, [ASSISTANT_ID]);
  return rows[0];
}

async function updateAssistantInstructions(instructions) {
  // Get current config
  const { rows } = await chatwootPool.query(`
    SELECT config FROM captain_assistants WHERE id = $1
  `, [ASSISTANT_ID]);

  const config = rows[0]?.config || {};
  config.instruction = instructions;

  await chatwootPool.query(`
    UPDATE captain_assistants
    SET config = $1, updated_at = NOW()
    WHERE id = $2
  `, [config, ASSISTANT_ID]);

  return config;
}

// ────────────────────────────────────────────────────────────
//  STATISTICS
// ────────────────────────────────────────────────────────────

async function getStats() {
  const [docs, faqs, tools, conv] = await Promise.all([
    chatwootPool.query(`SELECT COUNT(*) AS n, COALESCE(SUM(LENGTH(content)), 0) AS bytes FROM captain_documents WHERE assistant_id = $1`, [ASSISTANT_ID]),
    chatwootPool.query(`SELECT COUNT(*) AS n FROM captain_assistant_responses WHERE assistant_id = $1`, [ASSISTANT_ID]),
    chatwootPool.query(`SELECT COUNT(*) AS n, COUNT(*) FILTER (WHERE enabled = TRUE) AS active FROM captain_custom_tools WHERE account_id = $1`, [ACCOUNT_ID]),
    chatwootPool.query(`SELECT COUNT(*) AS n FROM captain_inboxes WHERE captain_assistant_id = $1`, [ASSISTANT_ID])
  ]);

  return {
    documents: {
      total: parseInt(docs.rows[0].n),
      total_bytes: parseInt(docs.rows[0].bytes),
      total_kb: Math.round(parseInt(docs.rows[0].bytes) / 1024 * 10) / 10
    },
    faqs: { total: parseInt(faqs.rows[0].n) },
    tools: { total: parseInt(tools.rows[0].n), active: parseInt(tools.rows[0].active) },
    inboxes: { connected: parseInt(conv.rows[0].n) }
  };
}


// ────────────────────────────────────────────────────────────
//  LIVE REPLIES — Captain conversation history viewer
// ────────────────────────────────────────────────────────────

async function listCaptainReplies({ limit = 50, channel = null, since_hours = 24 } = {}) {
  const params = [ASSISTANT_ID, since_hours, parseInt(limit) || 50];
  let channelFilter = '';
  if (channel && channel !== 'all') {
    channelFilter = 'AND i.channel_type = $' + (params.length + 1);
    params.push(channel);
  }

  const sql = `
    WITH captain_msgs AS (
      SELECT
        m.id AS captain_msg_id,
        m.content AS captain_reply,
        m.created_at AS captain_at,
        m.conversation_id,
        m.inbox_id,
        m.content_attributes
      FROM messages m
      WHERE m.sender_type = 'Captain::Assistant'
        AND m.created_at > NOW() - ($2 || ' hours')::interval
        AND EXISTS (
          SELECT 1 FROM captain_inboxes ci
          WHERE ci.inbox_id = m.inbox_id AND ci.captain_assistant_id = $1
        )
    ),
    last_customer_msg AS (
      SELECT DISTINCT ON (cm.captain_msg_id)
        cm.captain_msg_id,
        m2.content AS customer_question,
        m2.created_at AS customer_at
      FROM captain_msgs cm
      LEFT JOIN messages m2
        ON m2.conversation_id = cm.conversation_id
        AND m2.message_type = 0
        AND m2.id < cm.captain_msg_id
      ORDER BY cm.captain_msg_id, m2.id DESC
    )
    SELECT
      cm.captain_msg_id,
      cm.conversation_id,
      cm.captain_at AT TIME ZONE 'Asia/Riyadh' AS reply_at,
      i.name AS inbox_name,
      i.channel_type,
      cont.name AS customer_name,
      cont.phone_number AS customer_phone,
      lcm.customer_question,
      cm.captain_reply,
      cm.content_attributes,
      c.status AS conv_status
    FROM captain_msgs cm
    JOIN inboxes i ON i.id = cm.inbox_id
    JOIN conversations c ON c.id = cm.conversation_id
    LEFT JOIN contacts cont ON cont.id = c.contact_id
    LEFT JOIN last_customer_msg lcm ON lcm.captain_msg_id = cm.captain_msg_id
    WHERE 1=1 ${channelFilter}
    ORDER BY cm.captain_at DESC
    LIMIT $3
  `;

  const { rows } = await chatwootPool.query(sql, params);
  return rows;
}

async function getRepliesStats(since_hours = 24) {
  const { rows } = await chatwootPool.query(`
    SELECT
      COUNT(*) AS total_replies,
      COUNT(DISTINCT m.conversation_id) AS conversations_touched,
      COUNT(*) FILTER (WHERE m.content ILIKE '%handoff%' OR m.content ILIKE '%تحويل%' OR m.content ILIKE '%أحوّلك%') AS handoffs,
      COUNT(*) FILTER (WHERE m.created_at > NOW() - INTERVAL '1 hour') AS last_hour,
      MIN(m.created_at) AT TIME ZONE 'Asia/Riyadh' AS oldest,
      MAX(m.created_at) AT TIME ZONE 'Asia/Riyadh' AS newest
    FROM messages m
    WHERE m.sender_type = 'Captain::Assistant'
      AND m.created_at > NOW() - ($1 || ' hours')::interval
      AND EXISTS (
        SELECT 1 FROM captain_inboxes ci
        WHERE ci.inbox_id = m.inbox_id AND ci.captain_assistant_id = $2
      )
  `, [since_hours, ASSISTANT_ID]);
  return rows[0];
}

async function getRepliesByChannel(since_hours = 24) {
  const { rows } = await chatwootPool.query(`
    SELECT
      i.channel_type,
      i.name AS inbox_name,
      COUNT(m.*) AS replies
    FROM messages m
    JOIN inboxes i ON i.id = m.inbox_id
    WHERE m.sender_type = 'Captain::Assistant'
      AND m.created_at > NOW() - ($1 || ' hours')::interval
      AND EXISTS (
        SELECT 1 FROM captain_inboxes ci
        WHERE ci.inbox_id = m.inbox_id AND ci.captain_assistant_id = $2
      )
    GROUP BY i.channel_type, i.name
    ORDER BY replies DESC
  `, [since_hours, ASSISTANT_ID]);
  return rows;
}


// ────────────────────────────────────────────────────────────
//  LEARNING — pending suggestions from agent-handled convs
// ────────────────────────────────────────────────────────────

async function listLearningSuggestions(status = 'pending', limit = 50) {
  const { rows } = await chatwootPool.query(`
    SELECT cls.*, 
           c.status AS conv_status
    FROM captain_learning_suggestions cls
    LEFT JOIN conversations c ON c.id = cls.conversation_id
    WHERE cls.status = $1
    ORDER BY cls.created_at DESC
    LIMIT $2
  `, [status, limit]);
  return rows;
}

async function getLearningSuggestion(id) {
  const { rows } = await chatwootPool.query(
    'SELECT * FROM captain_learning_suggestions WHERE id = $1',
    [id]
  );
  return rows[0];
}

async function approveLearningSuggestion(id, { question, answer, reviewer }) {
  return await chatwootPool.query('BEGIN').then(async () => {
    try {
      const sug = await getLearningSuggestion(id);
      if (!sug) throw new Error('suggestion not found');
      if (sug.status === 'approved') throw new Error('already approved');
      
      const finalQ = (question || sug.suggested_question || '').trim();
      const finalA = (answer || sug.suggested_answer || '').trim();
      if (!finalQ || !finalA) throw new Error('question or answer is empty');
      
      // Insert as FAQ
      const { rows: faqRows } = await chatwootPool.query(`
        INSERT INTO captain_assistant_responses
          (account_id, assistant_id, question, answer, status, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        RETURNING id
      `, [sug.account_id, sug.assistant_id, finalQ, finalA, 1]);
      const faqId = faqRows[0].id;
      
      // Generate embedding synchronously (Rails callback doesn't fire for raw INSERT)
      const embText = finalQ + ': ' + finalA;
      const vec = await generateEmbedding(embText);
      await chatwootPool.query(
        'UPDATE captain_assistant_responses SET embedding = $1::vector WHERE id = $2',
        [vectorLiteral(vec), faqId]
      );
      
      // Mark suggestion as approved
      await chatwootPool.query(`
        UPDATE captain_learning_suggestions
        SET status = 'approved',
            suggested_question = $1,
            suggested_answer = $2,
            reviewed_by = $3,
            reviewed_at = NOW(),
            created_faq_id = $4,
            updated_at = NOW()
        WHERE id = $5
      `, [finalQ, finalA, reviewer || 'admin', faqId, id]);
      
      await chatwootPool.query('COMMIT');
      
      // Trigger embedding (sync would be safer but requires Rails - we trust the FAQ embedding listener)
      // The Captain::AssistantResponse model's after_create_commit will enqueue UpdateEmbeddingJob automatically
      
      return { success: true, faq_id: faqId };
    } catch (err) {
      await chatwootPool.query('ROLLBACK');
      throw err;
    }
  });
}

async function rejectLearningSuggestion(id, { reason, reviewer }) {
  await chatwootPool.query(`
    UPDATE captain_learning_suggestions
    SET status = 'rejected',
        rejection_reason = $1,
        reviewed_by = $2,
        reviewed_at = NOW(),
        updated_at = NOW()
    WHERE id = $3 AND status = 'pending'
  `, [reason || 'manual', reviewer || 'admin', id]);
  return { success: true };
}

async function getLearningStats() {
  const { rows } = await chatwootPool.query(`
    SELECT status, COUNT(*) AS n
    FROM captain_learning_suggestions
    GROUP BY status
  `);
  const stats = { pending: 0, approved: 0, rejected: 0, edited: 0 };
  rows.forEach(r => { stats[r.status] = parseInt(r.n); });
  return stats;
}

async function fetchConversationContext(conversation_id) {
  const { rows } = await chatwootPool.query(`
    SELECT m.id, m.content, m.message_type, m.sender_type, 
           m.created_at, 
           CASE m.sender_type
             WHEN 'Contact' THEN cont.name
             WHEN 'User' THEN u.name
             WHEN 'Captain::Assistant' THEN 'QAYDAO AI'
             ELSE m.sender_type
           END AS sender_name
    FROM messages m
    LEFT JOIN contacts cont ON cont.id = m.sender_id AND m.sender_type = 'Contact'
    LEFT JOIN users u ON u.id = m.sender_id AND m.sender_type = 'User'
    WHERE m.conversation_id = $1
      AND (m.private = false OR m.private IS NULL)
    ORDER BY m.id
    LIMIT 50
  `, [conversation_id]);
  return rows;
}

module.exports = {
  // Documents
  listDocuments, getDocument, createDocument, updateDocument, deleteDocument,
  // FAQs
  listFAQs, createFAQ, updateFAQ, deleteFAQ,
  // Tools (read-only)
  listTools,
  // Assistant
  getAssistant, updateAssistantInstructions,
  // Replies viewer
  listCaptainReplies, getRepliesStats, getRepliesByChannel,
  // Learning
  listLearningSuggestions, getLearningSuggestion, approveLearningSuggestion,
  rejectLearningSuggestion, getLearningStats, fetchConversationContext,
  // Stats
  getStats,
  // Direct DB access
  pool: chatwootPool
};
