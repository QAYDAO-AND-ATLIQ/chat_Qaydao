# QAYDAO — prevent QAYDAO AI (Captain) from interrupting a human agent.
#
# Problem: Captain replies to any `pending` conversation. When a human agent
# (شيماء/مروة/Fai/Omar...) had already replied manually and the customer later
# sends another message, Captain would jump in on top of the agent (proven on
# conv #888 where مروة handled it, then Captain replied 17 days later).
#
# Fix: before Captain answers, check whether a REAL human agent has replied in
# this conversation. If so, stay silent and leave it to the human.
#
# "Real human reply" = outgoing, sender_type User, not private, AND
#   - NOT a WhatsApp template (additional_attributes has no template_params) — those are
#     the automated OOO / greeting messages, which must NOT silence Captain, and
#   - does not start with 🚨 (monitor system alerts) or 📲 (widget_bridge auto-send logs),
#     which are system notes posted as User messages, not agent replies.
#
# This is idempotent and safe: if Captain hasn't replied yet and no human has
# either, behaviour is unchanged. Loaded as an initializer; survives restarts.

Rails.application.config.to_prepare do
  next unless defined?(Captain::Conversation::ResponseBuilderJob)

  unless Captain::Conversation::ResponseBuilderJob.included_modules.map(&:name).include?('QaydaoNoInterrupt')
    mod = Module.new do
      def self.name = 'QaydaoNoInterrupt'

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
        false # على الخطأ: لا نمنع Captain (نفشل بأمان)
      end
    end
    Captain::Conversation::ResponseBuilderJob.prepend(mod)
    Rails.logger.info('[qaydao-no-interrupt] patch applied to Captain::Conversation::ResponseBuilderJob')
  end
end
