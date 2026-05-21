-- captain_learning_suggestions
-- Stores Q&A pairs mined from human-agent-handled conversations,
-- normalized by GPT-4o-mini, awaiting human review.
CREATE TABLE IF NOT EXISTS captain_learning_suggestions (
  id BIGSERIAL PRIMARY KEY,
  conversation_id BIGINT NOT NULL,
  account_id BIGINT NOT NULL DEFAULT 1,
  assistant_id BIGINT NOT NULL DEFAULT 1,
  original_question TEXT NOT NULL,
  original_agent_reply TEXT NOT NULL,
  agent_name TEXT,
  channel_type TEXT,
  suggested_question TEXT,
  suggested_answer TEXT,
  ai_reasoning TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  reviewed_by TEXT,
  reviewed_at TIMESTAMP WITH TIME ZONE,
  rejection_reason TEXT,
  created_faq_id BIGINT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(conversation_id, original_question)
);
CREATE INDEX IF NOT EXISTS idx_cls_status ON captain_learning_suggestions(status);
CREATE INDEX IF NOT EXISTS idx_cls_created ON captain_learning_suggestions(created_at DESC);
