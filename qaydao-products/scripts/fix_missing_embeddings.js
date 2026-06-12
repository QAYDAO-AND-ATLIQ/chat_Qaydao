// Fix embedding for FAQ #83 (and any other missing)
require('dotenv').config();
const { Pool } = require('pg');
const OpenAI = require('openai');

const pool = new Pool({
  host: '127.0.0.1', port: 5437,
  database: 'chatwoot_production',
  user: 'chatwoot_user',
  password: 'f5c0e58555c94b08befed4db5643cb89d549983e9d9e132d',
});
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

(async () => {
  const { rows } = await pool.query(`
    SELECT id, question, answer FROM captain_assistant_responses
    WHERE assistant_id = 1 AND embedding IS NULL
  `);
  console.log(`Found ${rows.length} FAQs missing embeddings`);
  
  for (const r of rows) {
    const text = `${r.question}: ${r.answer}`;
    const emb = await openai.embeddings.create({
      model: 'text-embedding-3-small', input: text, encoding_format: 'float'
    });
    const vec = '[' + emb.data[0].embedding.join(',') + ']';
    await pool.query(
      'UPDATE captain_assistant_responses SET embedding = $1::vector WHERE id = $2',
      [vec, r.id]
    );
    console.log(`  ✓ FAQ #${r.id}: ${r.question.slice(0, 50)}`);
  }
  
  await pool.end();
  console.log('done');
  process.exit(0);
})().catch(err => { console.error(err); process.exit(1); });
