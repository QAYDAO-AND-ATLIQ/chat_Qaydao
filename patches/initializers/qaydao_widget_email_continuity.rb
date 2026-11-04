# QAYDAO 2026-11-04 — Website-widget email continuity fix (approved by Rami, staging first).
#
# ROOT CAUSE: ConversationReplyMailer#reply_with_summary (offline widget visitor
# who left an email; channel_web_widgets.continuity_via_email = true) builds the
# Message-ID / In-Reply-To headers with ConversationReplyMailerHelper#channel_email_domain:
#     account.inbound_email_domain  (accounts.domain / MAILER_INBOUND_EMAIL_DOMAIN) -> empty
#     inbox.channel.email           -> a WebWidget channel has no email
#     => raise 'Channel email domain not present.'
# so every reply email died in Sidekiq (prod dead set: 3,740 jobs since 2026-06-18,
# 172 in the last 7 days, 1,026 conversations) and visitors never got the answer.
#
# WHY NOT set accounts.domain: the account has feature `inbound_emails` ON, so a
# domain would switch Reply-To to reply+<uuid>@<domain>, which needs MX/inbound
# routing that does not exist -> customer replies would bounce.
#
# FIX (only when the stock code has no domain / no inbox address):
#   * Message-ID domain falls back to QAYDAO_MAIL_MESSAGE_ID_DOMAIN, else the domain of
#     the account support email (QAYDAO <support@qaydao.com> -> qaydao.com). Header only.
#   * Reply-To for non-email inboxes without inbox.email_address and without inbound
#     routing = QAYDAO_WIDGET_REPLY_TO (default: the account support email, i.e.
#     support@qaydao.com) instead of the assigned agent's personal mailbox.
#   From/SMTP are unchanged (MAILER_SENDER_EMAIL via the existing SMTP relay).
#
# Bind-mount on web + sidekiq + sidekiq_captain (mail jobs run in sidekiq).

module QaydaoWidgetEmailContinuity
  private

  def channel_email_domain
    super
  rescue StandardError => e
    raise unless e.message.to_s.include?('Channel email domain not present')

    domain = qaydao_fallback_mail_domain
    raise if domain.blank?

    domain
  end

  def reply_email
    return super if should_use_conversation_email_address? || @inbox.email_address.present?

    qaydao_widget_reply_to.presence || super
  end

  def qaydao_fallback_mail_domain
    explicit = ENV.fetch('QAYDAO_MAIL_MESSAGE_ID_DOMAIN', '').strip
    return explicit if explicit.present?

    [@account&.support_email, ENV.fetch('MAILER_SENDER_EMAIL', nil)].each do |addr|
      d = qaydao_safe_parse_email(addr).to_s.split('@').last
      return d if d.present?
    end
    nil
  end

  def qaydao_widget_reply_to
    addr = ENV.fetch('QAYDAO_WIDGET_REPLY_TO', '').strip
    addr = @account&.support_email if addr.blank?
    qaydao_safe_parse_email(addr)
  end

  def qaydao_safe_parse_email(addr)
    return nil if addr.blank?

    parse_email(addr)
  rescue StandardError
    nil
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  Rails.application.config.to_prepare do
    begin
      if defined?(::ConversationReplyMailer) && !(::ConversationReplyMailer < QaydaoWidgetEmailContinuity)
        ::ConversationReplyMailer.prepend(QaydaoWidgetEmailContinuity)
      end
      Rails.logger.info('[qaydao-patch] widget email continuity fix applied (Message-ID domain fallback + support Reply-To)')
    rescue StandardError => e
      Rails.logger.error("[qaydao-patch] widget email continuity fix NOT applied: #{e.class} #{e.message}")
    end
  end
end
