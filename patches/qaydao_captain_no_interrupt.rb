# QAYDAO — Captain (QAYDAO AI) interruption control on ResponseBuilderJob.
#
#  (A) PAUSE WINDOW + MANUAL CONTROL  (upgraded 2026-05-31):
#      QAYDAO AI stays SILENT while a human agent is active on a conversation,
#      and RESUMES automatically once the agent is gone (e.g. end of shift).
#      Paused when EITHER:
#        * a real human agent reply (outgoing + User + non-private, excluding
#          WhatsApp templates and the system lines) happened within the last
#          3 hours -- rolling: each new agent reply extends the window; OR
#        * a manual pause label is active on the conversation:
#            ai-off        -> indefinite (until the resume macro removes it)
#            ai-off-1h     -> 1h from when the label was applied
#            ai-off-4h     -> 4h
#            ai-off-today  -> until end of day (Asia/Riyadh)
#      Agents toggle these via the pause/resume Macros (buttons in the conversation).
#
#  (B) UNWRAP NESTED JSON envelope before sending (conv #2106 fix).
#  (C) ESCALATE PRIORITY -> urgent on QAYDAO AI handoff (never downgrades).
#
# All idempotent, fail OPEN (any error -> Captain behaves normally), bind-mounted
# on web + sidekiq, surviving restarts/recreation.

Rails.application.config.to_prepare do
  next unless defined?(Captain::Conversation::ResponseBuilderJob)

  unless Captain::Conversation::ResponseBuilderJob.included_modules.map(&:name).include?('QaydaoNoInterrupt')
    mod = Module.new do
      def self.name = 'QaydaoNoInterrupt'

      QAYDAO_SUPPORT_TEAM_ID = 2
      QAYDAO_ESCALATION_LABEL = 'تصعيد'
      QAYDAO_SOFT_HANDOFF_PATTERNS = [
        'ممثلي خدمة العملاء',
        'لفريق خدمة العملاء',
        'رفع طلبك لخدمة العملاء',
        'لدى خدمة العملاء',
        'وجّهت رسالتك',
        'وجهت رسالتك',
        'تم توجيه رسالتك'
      ].freeze

      # -- (D) deterministic assign + label on handoff -------------------
      def qaydao_escalate_assign_and_label!(reason)
        return if @conversation.nil?
        if @conversation.team_id.blank?
          @conversation.update!(team_id: QAYDAO_SUPPORT_TEAM_ID)
          Rails.logger.info("[qaydao-escalate-assign] conv ##{@conversation.id} team -> #{QAYDAO_SUPPORT_TEAM_ID} (#{reason})")
        end
        unless @conversation.label_list.include?(QAYDAO_ESCALATION_LABEL)
          @conversation.add_labels([QAYDAO_ESCALATION_LABEL])
          Rails.logger.info("[qaydao-escalate-assign] conv ##{@conversation.id} label +#{QAYDAO_ESCALATION_LABEL} (#{reason})")
        end
        # QAYDAO 2026-06-09 (root fix): a soft/native handoff MUST take the conversation
        # OUT of the bot 'pending' pool, otherwise Captain::InboxPendingConversationsResolutionJob
        # auto-resolves it ~1h later (the old-moon-924 / #2806 bug). bot_handoff! -> status :open.
        if @conversation.reload.pending?
          @conversation.bot_handoff!
          Rails.logger.info("[qaydao-escalate-assign] conv ##{@conversation.id} bot_handoff! -> open (#{reason})")
        end
      rescue StandardError => e
        Rails.logger.warn("[qaydao-escalate-assign] failed for conv ##{@conversation&.id} (#{reason}): #{e.message}")
      end

      # -- (A) pause window + manual control -----------------------------
      def perform(conversation, assistant)
        if qaydao_captain_paused?(conversation)
          Rails.logger.info("[qaydao-no-interrupt] Captain silent on conv ##{conversation&.id} (human active or manual pause)")
          return
        end
        super
      end

      def qaydao_captain_paused?(conversation)
        return false if conversation.nil?
        qaydao_recent_human_reply?(conversation) || qaydao_manual_pause_active?(conversation)
      rescue StandardError => e
        Rails.logger.warn("[qaydao-no-interrupt] pause check failed for conv ##{conversation&.id}: #{e.message}")
        false
      end

      def qaydao_recent_human_reply?(conversation)
        last = Conversation.uncached do
          conversation.messages
                      .where(message_type: :outgoing, sender_type: 'User', private: false)
                      .where("NOT (additional_attributes ? 'template_params')")
                      .where("content NOT LIKE ? AND content NOT LIKE ?", '🚨%', '📲%')
                      .maximum(:created_at)
        end
        last.present? && last > 3.hours.ago
      end

      def qaydao_manual_pause_active?(conversation)
        rows = ActsAsTaggableOn::Tagging
                 .where(taggable_type: 'Conversation', taggable_id: conversation.id, context: 'labels')
                 .joins(:tag)
                 .where('tags.name LIKE ?', 'ai-off%')
                 .pluck('tags.name', 'taggings.created_at')
        now = Time.current
        rows.any? do |name, applied_at|
          at = applied_at.is_a?(Time) ? applied_at : Time.zone.parse(applied_at.to_s)
          case name
          when 'ai-off'       then true
          when 'ai-off-1h'    then at + 1.hour  > now
          when 'ai-off-4h'    then at + 4.hours > now
          when 'ai-off-today' then now < at.in_time_zone('Asia/Riyadh').end_of_day
          else false
          end
        end
      end

      # -- (B) unwrap nested JSON before sending -------------------------
      def create_messages
        if @response.is_a?(Hash) && @response['response'].is_a?(String)
          cleaned = qaydao_unwrap_nested_json(@response['response'])
          if cleaned != @response['response']
            Rails.logger.info("[qaydao-unwrap] unwrapped nested JSON in Captain reply (conv ##{@conversation&.id})")
            @response = @response.merge('response' => cleaned)
          end
        end
        super
        qaydao_detect_soft_handoff_and_escalate
      end

      def qaydao_detect_soft_handoff_and_escalate
        content = @response.is_a?(Hash) ? @response['response'].to_s : @response.to_s
        return if content.blank?
        return unless QAYDAO_SOFT_HANDOFF_PATTERNS.any? { |p| content.include?(p) }
        qaydao_escalate_assign_and_label!('soft-handoff')
      rescue StandardError => e
        Rails.logger.warn("[qaydao-escalate-assign] soft-handoff detect failed for conv ##{@conversation&.id}: #{e.message}")
      end

      def qaydao_unwrap_nested_json(text)
        t = text.to_s.strip
        3.times do
          break unless t.start_with?('{') && t.include?('"response"')
          begin
            parsed = JSON.parse(t)
            break unless parsed.is_a?(Hash) && parsed.key?('response')
            t = parsed['response'].to_s.strip
          rescue JSON::ParserError
            m = t.match(/"response"\s*:\s*"((?:[^"\\]|\\.)*)"/m)
            break unless m
            t = m[1].gsub('\\n', "\n").gsub('\\"', '"').gsub('\\\\', '\\').strip
            break
          end
        end
        t
      rescue StandardError => e
        Rails.logger.warn("[qaydao-unwrap] failed (conv ##{@conversation&.id}): #{e.message}")
        text
      end

      # -- (C) escalate priority to urgent on handoff --------------------
      def create_handoff_message(*args, **kwargs)
        super
        qaydao_escalate_priority_on_handoff
        qaydao_escalate_assign_and_label!('native-handoff')
      end

      def qaydao_escalate_priority_on_handoff
        return unless @conversation
        current = Conversation.priorities[@conversation.priority].to_i
        urgent  = Conversation.priorities['urgent']
        if @conversation.priority.nil? || current < urgent
          @conversation.update!(priority: :urgent)
          Rails.logger.info("[qaydao-escalate] conv ##{@conversation.id} priority -> urgent on QAYDAO AI handoff")
        end
      rescue StandardError => e
        Rails.logger.warn("[qaydao-escalate] failed for conv ##{@conversation&.id}: #{e.message}")
      end
    end
    Captain::Conversation::ResponseBuilderJob.prepend(mod)
    Rails.logger.info('[qaydao-patch] no-interrupt(v2 window+manual) + json-unwrap + priority-escalate + assign-label applied')
  end
end
