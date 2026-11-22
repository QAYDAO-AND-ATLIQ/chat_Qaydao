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
    after_create_commit :qaydao_mark_bot_purchase_intent

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

    # 2026-11-22: when QAYDAO AI hands a buyer to the team (purchase-intent rule: the bot writes
    # «طلبك المسجّل للمتابعة: <code/model>» with no order number), label the conversation with the
    # existing «عميل_محتمل» label and raise its priority so the team picks buyers up first.
    # Post-purchase handoffs carry a 9-digit order number and are left as they are. Fail-open.
    QAYDAO_INTENT_LINE = 'طلبك المسجّل للمتابعة'.freeze
    QAYDAO_ORDER_NO_REGEX = /(?<!\d)[2-3]\d{8}(?!\d)/

    def qaydao_mark_bot_purchase_intent
      return unless outgoing?
      return unless sender_type == 'Captain::Assistant'
      text = content.to_s
      public_intent = !private && text.include?(QAYDAO_INTENT_LINE) && !text.match?(QAYDAO_ORDER_NO_REGEX)
      # the handoff tool records its reason as a private note, e.g. «نية شراء مؤكدة مع كود منتج: …»
      private_intent = private && text.match?(/نية\s*(ال)?شراء|purchase intent/i)
      return unless public_intent || private_intent

      conv = conversation
      return if conv.nil?
      conv.add_labels(['عميل_محتمل'])
      conv.update(priority: :high) unless %w[high urgent].include?(conv.priority.to_s)
      Rails.logger.info("[qaydao-purchase-intent] conv ##{conversation_id} labelled عميل_محتمل + high priority")
    rescue StandardError => e
      Rails.logger.warn("[qaydao-purchase-intent] conv ##{conversation_id} error -> skipped (fail-open): #{e.message}")
    end
  end

  Rails.logger.info('[qaydao-patch] bot transfer de-duplication applied')
end
