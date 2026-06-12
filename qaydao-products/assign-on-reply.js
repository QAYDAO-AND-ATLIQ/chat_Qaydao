/**
 * QAYDAO — Assign-on-Reply webhook
 * =================================
 * Solves: round-robin auto-assignment is disabled, so new conversations land
 * in "غير معين" (unassigned). When a HUMAN agent sends the first reply, this
 * webhook assigns the conversation to that agent automatically.
 *
 * Mounted at: POST /products/api/webhook/chatwoot?secret=XXX
 * Registered as a Chatwoot account webhook for the "message_created" event.
 *
 * Safety:
 *   - secret-protected (ASSIGN_WEBHOOK_SECRET)
 *   - acts ONLY on outgoing messages authored by a real User (agent)
 *   - never acts on customer messages (contact) or Captain (agent_bot/captain)
 *   - skips if the conversation is already assigned
 *   - skips private notes (optional reply only)
 */
const BASE = process.env.CHATWOOT_BASE_URL || "https://chat.qaydao.com";
const TOKEN = process.env.CHATWOOT_API_TOKEN || "";
const ACCOUNT_ID = 1;

function log(msg) {
  const ts = new Date().toISOString().replace("T", " ").slice(0, 19);
  console.log(`${ts} [assign-on-reply] ${msg}`);
}

async function getAssignee(convId) {
  // Fetch current assignee to avoid races / missing payload meta
  try {
    const r = await fetch(`${BASE}/api/v1/accounts/${ACCOUNT_ID}/conversations/${convId}`, {
      headers: { api_access_token: TOKEN },
    });
    if (!r.ok) return undefined;
    const d = await r.json();
    return d?.meta?.assignee?.id || d?.assignee_id || null;
  } catch (e) {
    log(`getAssignee error conv ${convId}: ${e.message}`);
    return undefined;
  }
}

async function assign(convId, agentId) {
  const r = await fetch(`${BASE}/api/v1/accounts/${ACCOUNT_ID}/conversations/${convId}/assignments`, {
    method: "POST",
    headers: { "Content-Type": "application/json", api_access_token: TOKEN },
    body: JSON.stringify({ assignee_id: agentId }),
  });
  return r.ok;
}

function register(app) {
  app.post("/products/api/webhook/chatwoot", async (req, res) => {
    // 1. verify secret
    if (req.query.secret !== process.env.ASSIGN_WEBHOOK_SECRET) {
      return res.status(403).json({ error: "forbidden" });
    }
    // 2. ack immediately (Chatwoot expects fast 200)
    res.status(200).json({ ok: true });

    try {
      const e = req.body || {};
      if (e.event !== "message_created") return;
      if (e.message_type !== "outgoing") return;        // only agent-side messages
      if (e.private === true) return;                    // ignore private notes

      // sender must be a real human agent (User), not contact/captain/agent_bot
      const sender = e.sender || {};
      const senderType = String(sender.type || sender.sender_type || "").toLowerCase();
      if (senderType !== "user") return;                 // excludes contact, agent_bot, captain
      const agentId = sender.id;
      if (!agentId) return;

      const conv = e.conversation || {};
      const convId = conv.id;
      if (!convId) return;

      // 3. skip if already assigned (check live to be safe)
      let current = conv?.meta?.assignee?.id;
      if (current === undefined) current = await getAssignee(convId);
      if (current) return;                               // already assigned → leave it

      // 4. assign to the replying agent
      const ok = await assign(convId, agentId);
      log(`conv ${convId} → agent ${agentId} (${sender.name || "?"}) : ${ok ? "assigned" : "FAILED"}`);
    } catch (err) {
      log(`handler error: ${err.message}`);
    }
  });

  log("registered POST /products/api/webhook/chatwoot");
}

module.exports = { register };
