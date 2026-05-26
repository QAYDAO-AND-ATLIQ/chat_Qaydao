# QAYDAO — two safety patches on Captain's ResponseBuilderJob:
#
#  (A) NO-INTERRUPT: don't let QAYDAO AI reply after a REAL human agent has
#      replied (proven on conv #888). "Real human reply" = outgoing, User,
#      not private, NOT a WhatsApp template (the automated OOO/greeting), and
#      not a 🚨 monitor alert / 📲 widget_bridge log.
#
#  (B) UNWRAP NESTED JSON: sometimes a scenario sub-agent returns its answer as
#      a raw JSON string like {"response":"...","reasoning":"..."} (occasionally
#      duplicated/concatenated), which then got sent to the customer verbatim
#      (seen on conv #2106). Before creating the outgoing message we unwrap any
#      nested {"response":...} envelope and keep only the real text.
#
# Both are idempotent, fail open, and load as a bind-mounted initializer on web
# + sidekiq, surviving restarts/recreation.

Rails.application.config.to_prepare do
  next unless defined?(Captain::Conversation::ResponseBuilderJob)

  unless Captain::Conversation::ResponseBuilderJob.included_modules.map(&:name).include?('QaydaoNoInterrupt')
    mod = Module.new do
      def self.name = 'QaydaoNoInterrupt'

      # ── (A) no-interrupt ──────────────────────────────────────────────
      def perform(conversation, assistant)
        if qaydao_human_agent_replied?(conversation)
          Rails.logger.info("[qaydao-no-interrupt] Captain skipped conv ##{conversation.id}: human agent already replied")
          return
        end
        super
      end

      def qaydao_human_agent_replied?(conversation)
        Conversation.uncached do
          conversation.messages
                      .where(message_type: :outgoing, sender_type: 'User', private: false)
                      .where("NOT (additional_attributes ? 'template_params')")
                      .where("content NOT LIKE ? AND content NOT LIKE ?", '🚨%', '📲%')
                      .exists?
        end
      rescue StandardError => e
        Rails.logger.warn("[qaydao-no-interrupt] check failed for conv ##{conversation&.id}: #{e.message}")
        false
      end

      # ── (B) unwrap nested JSON before sending ─────────────────────────
      def create_messages
        if @response.is_a?(Hash) && @response['response'].is_a?(String)
          cleaned = qaydao_unwrap_nested_json(@response['response'])
          if cleaned != @response['response']
            Rails.logger.info("[qaydao-unwrap] unwrapped nested JSON in Captain reply (conv ##{@conversation&.id})")
            @response = @response.merge('response' => cleaned)
          end
        end
        super
      end

      # Peels up to 3 levels of {"response":"...","reasoning":"..."} wrapping.
      # Handles valid JSON, and the broken duplicated/concatenated case
      # ({...}{...}) via a regex fallback that grabs the first "response" value.
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
    end
    Captain::Conversation::ResponseBuilderJob.prepend(mod)
    Rails.logger.info('[qaydao-patch] no-interrupt + json-unwrap applied to Captain::Conversation::ResponseBuilderJob')
  end
end
