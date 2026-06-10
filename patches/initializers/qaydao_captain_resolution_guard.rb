# QAYDAO 2026-06-09 — Resolution guard for Captain auto-resolve.
#
# ROOT BUG (conv old-moon-924 / #2806, #1549, #1261):
#   Captain::InboxPendingConversationsResolutionJob auto-resolves any conversation
#   still in 'pending' (bot-owned) status and idle > 1h. In 'evaluated' mode an LLM
#   (Captain::ConversationCompletionService) decides resolve-vs-handoff and sometimes
#   WRONGLY resolves a conversation where the customer explicitly asked for a human
#   (or the bot already promised "وجّهت رسالتك لفريق خدمة العملاء").
#
# DETERMINISTIC GUARANTEE (independent of the LLM):
#   Never auto-RESOLVE a conversation that:
#     * already has a human assignee            -> skip (leave for the agent), OR
#     * carries the escalation label 'تصعيد', OR
#     * contains a human-handoff signal (bot transfer phrase OR explicit customer
#       request for a human) -> hand off (bot_handoff! => :open + escalate) instead.
#
# Idempotent. fail-SAFE: on any error we SKIP resolving (never wrongly close).
# Bind-mounted on web + sidekiq; survives restarts/upgrades.

Rails.application.config.to_prepare do
  next unless defined?(Captain::InboxPendingConversationsResolutionJob)

  klass = Captain::InboxPendingConversationsResolutionJob
  unless klass.included_modules.map(&:name).include?('QaydaoResolutionGuard')
    mod = Module.new do
      def self.name = 'QaydaoResolutionGuard'

      QAYDAO_ESCALATION_LABEL = 'تصعيد'
      QAYDAO_HUMAN_SIGNAL_PATTERNS = [
        # bot transfer phrases (soft handoff)
        'لفريق خدمة العملاء', 'ممثلي خدمة العملاء', 'رفع طلبك لخدمة العملاء',
        'لدى خدمة العملاء', 'وجّهت رسالتك', 'وجهت رسالتك', 'تم توجيه رسالتك',
        'سيتواصل معك فريق', 'سيتواصلون معك',
        # explicit customer requests for a human
        'اتواصل مع', 'أتواصل مع', 'ابغى اكلم', 'أبغى أكلم', 'ابي اكلم', 'أبي أكلم',
        'كلموني', 'حولني', 'حوّلني', 'حولوني', 'موظف', 'ممثل', 'مندوب',
        'شخص يفيدني', 'احد يساعدني', 'أحد يساعدني', 'بشري'
      ].freeze

      # Evaluated mode (active config) routes every close through resolve_conversation.
      def resolve_conversation(conversation, inbox, reason)
        if conversation.assignee_id.present?
          Rails.logger.info("[qaydao-resolve-guard] conv ##{conversation.id} has human assignee -> skip auto-resolve")
          return
        end
        if qaydao_conversation_needs_human?(conversation)
          Rails.logger.info("[qaydao-resolve-guard] conv ##{conversation.id} human-handoff signal -> handoff instead of resolve")
          handoff_conversation(conversation, inbox, reason)
          return
        end
        super
      rescue StandardError => e
        Rails.logger.warn("[qaydao-resolve-guard] conv ##{conversation&.id} guard error -> SKIP resolve (fail-safe): #{e.message}")
        nil
      end

      # Belt-and-suspenders: also guard the time-based path (if auto_resolve_evaluated is ever off).
      def perform_time_based(inbox)
        Current.executed_by = inbox.captain_assistant
        resolvable_pending_conversations(inbox).each do |conversation|
          if conversation.assignee_id.present? || qaydao_conversation_needs_human?(conversation)
            Rails.logger.info("[qaydao-resolve-guard] (time-based) conv ##{conversation.id} needs human -> handoff")
            begin
              handoff_conversation(conversation, inbox, 'human handoff signal detected')
            rescue StandardError => e
              Rails.logger.warn("[qaydao-resolve-guard] (time-based) handoff failed conv ##{conversation.id}: #{e.message}")
            end
            next
          end
          create_resolution_message(conversation, inbox)
          conversation.resolved!
        end
      rescue StandardError => e
        Rails.logger.warn("[qaydao-resolve-guard] time-based guard error: #{e.message}")
      end

      def qaydao_conversation_needs_human?(conversation)
        return true if conversation.label_list.include?(QAYDAO_ESCALATION_LABEL)

        likes = QAYDAO_HUMAN_SIGNAL_PATTERNS.map { |p| "%#{p}%" }
        conversation.messages.where('content ILIKE ANY (ARRAY[?])', likes).exists?
      rescue StandardError => e
        Rails.logger.warn("[qaydao-resolve-guard] needs_human? error conv ##{conversation&.id}: #{e.message}")
        true # fail-safe: when unsure, treat as needing a human (never wrongly resolve)
      end
    end

    klass.prepend(mod)
    Rails.logger.info('[qaydao-patch] captain resolution-guard applied (no auto-resolve when a human is required)')
  end

  # ---------------------------------------------------------------------------
  # QAYDAO 2026-06-10 (Fix D) — MODEL-LEVEL RESOLUTION LOCK after handoff.
  #
  # Bug pattern (conv #2831 / old-moon-924): conversation correctly handed off
  # (assigned + urgent), then 12s later resolved via the WIDGET path attributed
  # to the customer + CSAT fired — agent never got to reply.
  #
  # Rule: a conversation carrying the escalation label 'تصعيد' can ONLY be
  # resolved by a human agent (Current.user is a User), or by anyone AFTER a
  # human agent has actually replied (post-escalation). Covers ALL paths:
  # widget toggle_status, bot resolved!, API — because it sits on the model.
  # Fail-open on errors (never block agents due to a guard bug).
  # ---------------------------------------------------------------------------
  if defined?(Conversation) && !Conversation.included_modules.map(&:name).include?('QaydaoResolutionLock')
    lock = Module.new do
      def self.name = 'QaydaoResolutionLock'

      QAYDAO_LOCK_LABEL = 'تصعيد'

      def toggle_status
        # toggle resolves only FROM open (open -> resolved); pending -> open must stay allowed
        if open? && qaydao_resolution_locked?
          Rails.logger.info("[qaydao-resolution-lock] blocked toggle_status->resolved on conv ##{id} (escalated, awaiting agent reply)")
          return false
        end
        super
      end

      def resolved!(*args)
        if qaydao_resolution_locked?
          Rails.logger.info("[qaydao-resolution-lock] blocked resolved! on conv ##{id} (escalated, awaiting agent reply)")
          return false
        end
        super
      end

      def qaydao_resolution_locked?
        return false if Current.user.is_a?(::User) # human agent action — always allowed
        return false unless label_list.include?(QAYDAO_LOCK_LABEL)

        escalated_at = ActsAsTaggableOn::Tagging
                         .joins(:tag)
                         .where(taggable_type: 'Conversation', taggable_id: id, context: 'labels')
                         .where(tags: { name: QAYDAO_LOCK_LABEL })
                         .minimum(:created_at)
        return false if escalated_at.nil?

        agent_replied = messages
                          .where(message_type: :outgoing, sender_type: 'User', private: false)
                          .where('messages.created_at >= ?', escalated_at)
                          .where("NOT (additional_attributes ? 'template_params')")
                          .exists?
        !agent_replied
      rescue StandardError => e
        Rails.logger.warn("[qaydao-resolution-lock] check failed conv ##{id}: #{e.message} — allowing (fail-open)")
        false
      end
    end

    Conversation.prepend(lock)
    Rails.logger.info('[qaydao-patch] conversation resolution-lock applied (escalated convs close only by/after a human agent)')
  end
end
