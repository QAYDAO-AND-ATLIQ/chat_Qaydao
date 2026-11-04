# QAYDAO 2026-11-02 — Bot transfer-message de-duplication (cost policy, approved by Rami).
#
# WHY: since 2026-10-01 Meta bills every WhatsApp service message (after the
# first 1,000/month). In October QAYDAO AI sent 2,540 "transfer" messages in
# 1,477 conversations — 1,063 were repeats of a transfer the customer had
# already received (the LLM's own "تم توجيه رسالتك…" plus the idle-guard's
# "تم تحويل محادثتك…", or the same conversation handed off again on the next
# idle sweep). Each repeat is billed and reads as spam.
#
# RULE (deterministic, LLM-independent):
#   A public outgoing message from Captain::Assistant whose text is a transfer
#   notice is converted to a PRIVATE note (not sent to the customer) when the
#   same conversation already got a public bot transfer notice
#     * within the last 24 hours, and
#     * with no public human-agent message since.
#   The handoff itself (bot_handoff!, labels, assignment) is untouched — only the
#   repeated customer-facing text is suppressed. Human messages are never touched.
#   Fail-open: any error lets the message through unchanged.
#
# Bind-mount on web + sidekiq + sidekiq_captain (messages are created in all three).

Rails.application.config.to_prepare do
  next unless defined?(::Message)
  next if ::Message.respond_to?(:qaydao_transfer_dedupe_installed?)

  ::Message.class_eval do
    QAYDAO_TRANSFER_REGEX = /(تم تحويل محادثتك|تم توجيه رسالتك|يسعدنا تحويلك|سيتم تحويلك|سأحوّلك|سأحولك|وجّهت رسالتك|وجهت رسالتك|سيتواصل معك فريق|سيتواصلون معك)/
    QAYDAO_TRANSFER_WINDOW = 24.hours
    QAYDAO_TRANSFER_NOTE_PREFIX = '[إشعار تحويل مكرر — لم يُرسل للعميل]'.freeze

    def self.qaydao_transfer_dedupe_installed? = true

    before_create :qaydao_suppress_repeated_bot_transfer

    private

    def qaydao_suppress_repeated_bot_transfer
      return unless outgoing? && !private
      return unless sender_type == 'Captain::Assistant'
      return unless content.to_s.match?(QAYDAO_TRANSFER_REGEX)
      return if conversation_id.blank?

      since = Time.now.utc - QAYDAO_TRANSFER_WINDOW
      base = ::Message.where(conversation_id: conversation_id, message_type: :outgoing, private: false)
      last_human_at = base.where(sender_type: 'User').maximum(:created_at)
      floor = [since, last_human_at].compact.max

      earlier = base.where(sender_type: 'Captain::Assistant')
                    .where('created_at > ?', floor)
                    .where('content ~ ?', QAYDAO_TRANSFER_REGEX.source)
                    .exists?
      return unless earlier

      self.private = true
      self.content = "#{QAYDAO_TRANSFER_NOTE_PREFIX}\n#{content}"
      Rails.logger.info("[qaydao-transfer-dedupe] conv ##{conversation_id} repeated bot transfer suppressed")
    rescue StandardError => e
      Rails.logger.warn("[qaydao-transfer-dedupe] conv ##{conversation_id} error -> allow (fail-open): #{e.message}")
    end
  end

  Rails.logger.info('[qaydao-patch] bot transfer de-duplication applied')
end
