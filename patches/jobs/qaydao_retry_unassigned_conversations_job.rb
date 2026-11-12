# QAYDAO 2026-05-05: Retry assignment for unassigned conversations every 5 minutes.
#
# Why this exists:
#   Chatwoot's auto-assignment runs only when conversation status changes to 'open'
#   (or resolved/snoozed). If no team agent is online at that moment, the conversation
#   stays unassigned forever — even after agents come back online.
#
# What this job does (every 5 minutes):
#   1. For each target inbox, call existing AutoAssignment::AssignmentJob — this
#      uses the team-based round-robin (مروة + أميرة via team 2).
#   2. Overflow to Maher (2026-11-12, قرار رامي): ماهر خارج التوزيع العادي، ويدخل
#      فقط عند الضغط على مروة وأميرة. انظر overflow_to_maher أدناه.
#
# Idempotent: if everyone is already assigned, the job exits cheaply.
# Safe on errors: per-inbox try/rescue isolates failures; overflow is fail-open (does nothing).
class QaydaoRetryUnassignedConversationsJob < ApplicationJob
  TARGET_INBOX_IDS  = [2, 3, 5, 6].freeze     # Email, WebWidget, WhatsApp, Instagram
  PRIMARY_TEAM_ID   = 2                       # الدعم الفني
  FALLBACK_EMAILS   = %w[].freeze  # 2026-11-12: أُزيلت fay@ بعد مغادرتها (قرار رامي) — لا احتياطي فردي

  # --- Overflow to Maher (2026-11-12) -------------------------------------------
  # تعريف «الضغط»: الموظفة عليها OVERLOAD_AWAITING محادثات أو أكثر آخر رسالة فيها
  # من العميل ولم يُرد عليها، أو أنها غير متصلة. عندها فقط تُنقل لماهر المحادثات
  # التي ينتظر فيها العميل WAIT_MINUTES دقيقة أو أكثر ولم يرد عليها أي موظف بشري
  # بعد (لا نسحب محادثة بدأت فيها مروة أو أميرة الحوار). ماهر يجب أن يكون متصلاً،
  # وسقف ما يُحمّل عليه MAHER_CAP محادثة منتظرة في نفس الوقت.
  OVERFLOW_EMAIL      = 'maher@qaydao.com'.freeze
  PRIMARY_AGENT_EMAILS = %w[marwa@qaydao.com amira@qaydao.com].freeze
  OVERLOAD_AWAITING   = 5
  WAIT_MINUTES        = 10
  MAHER_CAP           = 8
  OVERFLOW_LOG_KEY    = 'QAYDAO_OVERFLOW_LOG'.freeze  # redis-cli lrange alfred:QAYDAO_OVERFLOW_LOG 0 20

  queue_as :scheduled_jobs

  def perform
    TARGET_INBOX_IDS.each do |inbox_id|
      begin
        inbox = Inbox.find_by(id: inbox_id)
        next unless inbox&.enable_auto_assignment?

        process_inbox(inbox)
      rescue StandardError => e
        Rails.logger.error "[QAYDAO Retry] inbox=#{inbox_id} failed: #{e.class} #{e.message}"
      end
    end

    begin
      overflow_to_maher
    rescue StandardError => e
      Rails.logger.error "[QAYDAO Overflow] failed: #{e.class} #{e.message}"
    end
  end

  # Read-only preview, usable from rails runner:
  #   QaydaoRetryUnassignedConversationsJob.new.overflow_plan
  def overflow_plan
    account_id = Inbox.find(TARGET_INBOX_IDS.first).account_id
    online_ids = fetch_online_user_ids(account_id)
    maher = User.find_by(email: OVERFLOW_EMAIL)
    primaries = User.where(email: PRIMARY_AGENT_EMAILS).to_a
    awaiting = awaiting_counts
    overloaded = primaries.select { |u| !online_ids.include?(u.id) || awaiting[u.id].to_i >= OVERLOAD_AWAITING }
    all_overloaded = primaries.any? && overloaded.size == primaries.size
    room = maher ? [MAHER_CAP - awaiting[maher.id].to_i, 0].max : 0
    from_ids = overloaded.map(&:id)
    candidates = all_overloaded ? waiting_first_response(from_ids) : []
    {
      maher_online: maher && online_ids.include?(maher.id),
      awaiting: primaries.to_h { |u| [u.email, awaiting[u.id].to_i] }.merge(OVERFLOW_EMAIL => maher ? awaiting[maher.id].to_i : nil),
      online: primaries.to_h { |u| [u.email, online_ids.include?(u.id)] },
      all_overloaded: all_overloaded,
      room: room,
      candidates: candidates.first(room).map(&:display_id),
      maher: maher
    }
  end

  private

  def process_inbox(inbox)
    # Step 1: regular team-based assignment (uses existing service, respects team_id)
    AutoAssignment::AssignmentJob.perform_now(inbox_id: inbox.id)

    # Step 2: individual fallback if primary team is fully offline (list currently empty)
    fallback_if_team_offline(inbox)
  end

  def overflow_to_maher
    plan = overflow_plan
    maher = plan[:maher]
    return unless maher && plan[:maher_online] && plan[:all_overloaded]
    return if plan[:candidates].empty?

    moved = []
    Conversation.where(display_id: plan[:candidates], inbox_id: TARGET_INBOX_IDS).find_each do |conv|
      from = conv.assignee&.name || 'غير مسندة'
      conv.update!(assignee: maher)
      moved << { id: conv.display_id, from: from }
    end
    return if moved.empty?

    entry = { at: Time.now.utc.iso8601, moved: moved, awaiting: plan[:awaiting] }.to_json
    begin
      ::Redis::Alfred.lpush(OVERFLOW_LOG_KEY, entry)
      $alfred.with { |conn| conn.ltrim(OVERFLOW_LOG_KEY, 0, 999) }
    rescue StandardError => e
      Rails.logger.warn "[QAYDAO Overflow] log write failed: #{e.class}"
    end
    Rails.logger.info "[QAYDAO Overflow] moved=#{moved.size} to=#{maher.email} #{entry}"
  rescue StandardError => e
    Rails.logger.error "[QAYDAO Overflow] move failed: #{e.class} #{e.message}"
  end

  # Open conversations whose last public message is from the customer, per assignee.
  def awaiting_counts
    sql = <<~SQL.squish
      SELECT c.assignee_id, COUNT(*) FROM conversations c
      WHERE c.status = 0 AND c.inbox_id IN (#{TARGET_INBOX_IDS.join(',')}) AND c.assignee_id IS NOT NULL
        AND (SELECT m.message_type FROM messages m
             WHERE m.conversation_id = c.id AND m.private = false AND m.message_type IN (0,1)
             ORDER BY m.id DESC LIMIT 1) = 0
      GROUP BY c.assignee_id
    SQL
    ActiveRecord::Base.connection.select_rows(sql).to_h { |a, n| [a.to_i, n.to_i] }
  end

  # Customer waiting >= WAIT_MINUTES, no human agent has replied yet, assigned to an
  # overloaded primary agent or unassigned. Oldest wait first.
  def waiting_first_response(from_ids)
    ids_sql = (from_ids.map(&:to_i) + [0]).join(',')
    sql = <<~SQL.squish
      SELECT c.id FROM conversations c
      JOIN LATERAL (SELECT m.message_type, m.created_at FROM messages m
                    WHERE m.conversation_id = c.id AND m.private = false AND m.message_type IN (0,1)
                    ORDER BY m.id DESC LIMIT 1) last ON true
      WHERE c.status = 0 AND c.inbox_id IN (#{TARGET_INBOX_IDS.join(',')})
        AND (c.assignee_id IS NULL OR c.assignee_id IN (#{ids_sql}))
        AND last.message_type = 0
        AND last.created_at <= NOW() - INTERVAL '#{WAIT_MINUTES.to_i} minutes'
        AND NOT EXISTS (SELECT 1 FROM messages h WHERE h.conversation_id = c.id
                        AND h.message_type = 1 AND h.private = false AND h.sender_type = 'User')
      ORDER BY last.created_at ASC
      LIMIT 50
    SQL
    ids = ActiveRecord::Base.connection.select_values(sql)
    Conversation.where(id: ids).index_by(&:id).values_at(*ids.map(&:to_i)).compact
  end

  def fallback_if_team_offline(inbox)
    return if FALLBACK_EMAILS.empty?

    online_ids = fetch_online_user_ids(inbox.account_id)

    # If any primary team member is online, do nothing — they should handle it.
    team_member_ids = Team.find(PRIMARY_TEAM_ID).members.ids
    return if (team_member_ids & online_ids).any?

    fallback_user = find_online_fallback(online_ids)
    return unless fallback_user

    assigned = 0
    inbox.conversations.where(status: 'open', assignee_id: nil).find_each do |conv|
      conv.update!(assignee: fallback_user)
      assigned += 1
    end

    Rails.logger.info(
      "[QAYDAO Fallback] inbox=#{inbox.id} assigned=#{assigned} to=#{fallback_user.email} " \
      "(primary team fully offline)"
    ) if assigned.positive?
  end

  def find_online_fallback(online_ids)
    FALLBACK_EMAILS.each do |email|
      user = User.find_by(email: email)
      return user if user && online_ids.include?(user.id)
    end
    nil
  end

  def fetch_online_user_ids(account_id)
    OnlineStatusTracker.get_available_users(account_id)
                       .select { |_, value| value == 'online' }
                       .keys.map(&:to_i)
  end
end
