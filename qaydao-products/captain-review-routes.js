// مسارات «مراجعة الكابتن اليومية» — تُسجَّل من server.js
const path = require('path');
const crypto = require('crypto');
const review = require('./captain-review');

function safeEq(a, b) {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length > 0 && x.length === y.length && crypto.timingSafeEqual(x, y);
}

// نداءات خادم-لخادم من فريقي فقط (توكن مشترك في .env الطرفين)
function requireInternal(req, res, next) {
  const tok = process.env.CAPTAIN_REVIEW_TOKEN;
  if (!tok) return res.status(503).json({ error: 'captain review is not configured' });
  if (!safeEq(req.headers['x-review-token'], tok)) return res.status(401).json({ error: 'unauthorized' });
  next();
}

function register(app, { requireAuth, logAudit }) {
  review.ensureSchema().catch(e => console.error('[captain-review] schema', e.message));

  // ── فريقي ──
  app.post('/products/api/internal/captain-review/generate', requireInternal, async (req, res) => {
    try {
      const { date, reviewers, quota } = req.body || {};
      res.json(await review.generate({ date, reviewers, quota }));
    } catch (err) { res.status(400).json({ error: err.message }); }
  });

  app.get('/products/api/internal/captain-review/status', requireInternal, async (req, res) => {
    try {
      const emails = req.query.emails ? String(req.query.emails).split(',') : null;
      res.json(await review.status({ date: req.query.date, from: req.query.from, to: req.query.to, emails }));
    } catch (err) { res.status(400).json({ error: err.message }); }
  });

  // ── الموظف ──
  app.get('/products/captain/today', requireAuth, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'captain-today.html'));
  });

  app.get('/products/api/captain/review/mine', requireAuth, async (req, res) => {
    try {
      const email = req.actor && req.actor.email;
      if (!email) return res.json({ date: review.riyadhToday(), total: 0, done: 0, items: [], identity: false,
                                    me: req.actor ? req.actor.name : null });
      const out = await review.mine({ email, date: req.query.date });
      res.json({ ...out, identity: true, me: req.actor.name });
    } catch (err) { res.status(500).json({ error: err.message }); }
  });

  // «الرد صحيح» — الإجراء الوحيد الجديد؛ التصحيح والاعتماد والرفض تمر بمساراتها القائمة
  app.post('/products/api/captain/review/items/:id/ok', requireAuth, async (req, res) => {
    try {
      const item = await review.getItem(parseInt(req.params.id));
      if (!item || item.item_type !== 'reply') return res.status(404).json({ error: 'not found' });
      if (item.status === 'expired') return res.status(409).json({ error: 'انتهت صلاحية هذا البند' });
      await logAudit(req, 'reply.ok', `أكّد صحة رد QAYDAO AI #${item.ref_id}`,
        { target_type: 'reply', target_id: item.ref_id, details: { review_item: item.id } });
      res.json({ success: true });
    } catch (err) { res.status(400).json({ error: err.message }); }
  });
}

module.exports = { register };
