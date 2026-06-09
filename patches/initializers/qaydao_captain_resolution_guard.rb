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
end
