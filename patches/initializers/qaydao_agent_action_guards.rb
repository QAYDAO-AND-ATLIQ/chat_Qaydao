# QAYDAO 2026-11-04 — Agent action guards (approved by Rami, staging first).
#
# (1) UNASSIGN GUARD — accountability. Setting a conversation's assignee to
#     "none" is allowed ONLY for users whose email is in
#     QAYDAO_UNASSIGN_ALLOWED_EMAILS (default "rami@qaydao.com,maher@qaydao.com").
#     Everyone else gets a clear Arabic error. Transfers to a NAMED agent, an
#     agent bot, or a team keep working (a team transfer may still clear the
#     assignee through Chatwoot's own ensure_assignee_is_from_team — by design).
#     System paths (no Current.user: sidekiq jobs, Captain, automation rules,
#     round-robin, QaydaoRetryUnassignedConversationsJob) are never blocked.
#
# (2) SNOOZE GUARD — the customer must not be parked while waiting.
#     * "Snooze until next reply" (no snoozed_until) is refused when the last
#       public incoming/outgoing message is from the contact.
#     * ANY snooze is refused on conversations carrying a label in
#       QAYDAO_NO_SNOOZE_LABELS (default "وزارة_التجارة").
#     Snooze WITH a date stays allowed otherwise. Applies to every human user.
#
# Enforcement layers:
#   * controllers (clean 4xx JSON the UI can show):
#       Conversations::AssignmentsController#create          -> 403
#       ConversationsController#toggle_status (status=snoozed) -> 422
#       BulkActionsController#create (fields.assignee_id / status=snoozed) -> 403 / 422
#   * Conversation validation (backstop for every other path that runs with a
#     human Current.user: bulk job, macros, future endpoints) -> RecordInvalid.
#   Response body: { error:, message:, qaydao_guard: <code> } — the dashboard
#   helper /qaydao-action-guard.js shows `message` as a toast (the stock store
#   actions swallow API errors, so without it the agent would see a false
#   "success" toast).
#
# Fail-open: any unexpected exception in a check is logged and the action is allowed.
# Bind-mount on web + sidekiq + sidekiq_captain.

module QaydaoActionGuards
  module_function

  UNASSIGN_MSG = 'لا يمكن إلغاء إسناد المحادثة. إلغاء الإسناد متاح للمدير فقط — إن لم تكن المحادثة من اختصاصك فحوّلها إلى موظف أو فريق بالاسم.'.freeze
  SNOOZE_WAITING_MSG = 'لا يمكن تأجيل المحادثة «حتى الرد التالي» لأن آخر رسالة من العميل وهو بانتظار ردك. رُدّ على العميل أولاً، أو اختر تأجيلاً بموعد محدد.'.freeze
  SNOOZE_LABEL_MSG = 'لا يمكن تأجيل هذه المحادثة لأنها موسومة «%<label>s». الرد مطلوب خلال ساعة عمل برد فعلي ومستندات.'.freeze

  def list_env(name, default)
    ENV.fetch(name, default).to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def allowed_unassign_emails
    list_env('QAYDAO_UNASSIGN_ALLOWED_EMAILS', 'rami@qaydao.com,maher@qaydao.com').map(&:downcase)
  end

  def no_snooze_labels
    list_env('QAYDAO_NO_SNOOZE_LABELS', 'وزارة_التجارة')
  end

  def human?(user)
    defined?(::User) && user.is_a?(::User)
  end

  def may_unassign?(user)
    return true unless human?(user)

    allowed_unassign_emails.include?(user.email.to_s.downcase)
  end

  def blank_assignee?(value)
    v = value.to_s.strip
    v.empty? || %w[0 nil null none].include?(v.downcase)
  end

  def payload(code, message)
    { error: message, message: message, qaydao_guard: code.to_s }
  end

  # [code, message] when the user may not remove the assignee of this conversation, else nil
  def unassign_refusal(user, conversation)
    return nil if may_unassign?(user)
    return nil if conversation.nil? || conversation.assignee_id.to_i <= 0

    [:unassign_forbidden, UNASSIGN_MSG]
  rescue StandardError => e
    Rails.logger.warn("[qaydao-guard] unassign check failed conv ##{conversation&.id} -> allow: #{e.class} #{e.message}")
    nil
  end

  # [code, message] when this snooze must be refused, else nil
  def snooze_refusal(user, conversation, with_date)
    return nil unless human?(user)
    return nil if conversation.nil?

    labels = conversation.label_list.to_a
    blocked_label = no_snooze_labels.find { |l| labels.include?(l) }
    return [:snooze_label, format(SNOOZE_LABEL_MSG, label: blocked_label)] if blocked_label
    return nil if with_date

    last = conversation.messages
                       .where(private: false, message_type: %i[incoming outgoing])
                       .reorder(created_at: :desc, id: :desc).first
    return [:snooze_customer_waiting, SNOOZE_WAITING_MSG] if last&.incoming?

    nil
  rescue StandardError => e
    Rails.logger.warn("[qaydao-guard] snooze check failed conv ##{conversation&.id} -> allow: #{e.class} #{e.message}")
    nil
  end

  def log_refusal(code, user, conversation_ids)
    Rails.logger.info("[qaydao-guard] REFUSED #{code} user=#{user&.email} conv=#{Array(conversation_ids).join(',')}")
  end

  # -- controllers -----------------------------------------------------------
  module AssignmentsGuard
    def create
      if params.key?(:assignee_id) && !agent_bot_assignment? && QaydaoActionGuards.blank_assignee?(params[:assignee_id])
        refusal = QaydaoActionGuards.unassign_refusal(Current.user, @conversation)
        if refusal
          QaydaoActionGuards.log_refusal(refusal[0], Current.user, @conversation.display_id)
          return render(json: QaydaoActionGuards.payload(*refusal), status: :forbidden)
        end
      end
      super
    end
  end

  module ToggleStatusGuard
    def toggle_status
      if params[:status].to_s == 'snoozed'
        refusal = QaydaoActionGuards.snooze_refusal(Current.user, @conversation, params[:snoozed_until].present?)
        if refusal
          QaydaoActionGuards.log_refusal(refusal[0], Current.user, @conversation.display_id)
          return render(json: QaydaoActionGuards.payload(*refusal), status: :unprocessable_entity)
        end
      end
      super
    end
  end

  module BulkGuard
    def create
      refusal = qaydao_bulk_refusal
      if refusal
        return render(json: QaydaoActionGuards.payload(refusal[0], refusal[1]), status: refusal[2])
      end

      super
    end

    private

    def qaydao_bulk_refusal
      return nil unless params[:type].to_s.camelize == 'Conversation'

      user = Current.user
      return nil unless QaydaoActionGuards.human?(user)

      fields = params[:fields]
      return nil unless fields.respond_to?(:key?)

      conversations = Current.account.conversations.where(display_id: Array(params[:ids]))

      if fields.key?(:assignee_id) && QaydaoActionGuards.blank_assignee?(fields[:assignee_id]) && !QaydaoActionGuards.may_unassign?(user)
        assigned = conversations.where.not(assignee_id: nil).pluck(:display_id)
        if assigned.any?
          QaydaoActionGuards.log_refusal(:unassign_forbidden, user, assigned)
          return [:unassign_forbidden, QaydaoActionGuards::UNASSIGN_MSG, :forbidden]
        end
      end

      if fields[:status].to_s == 'snoozed'
        with_date = params[:snoozed_until].present?
        blocked = conversations.filter_map do |c|
          r = QaydaoActionGuards.snooze_refusal(user, c, with_date)
          [c.display_id, r] if r
        end
        if blocked.any?
          ids = blocked.map(&:first)
          QaydaoActionGuards.log_refusal(blocked.first[1][0], user, ids)
          msg = blocked.first[1][1]
          msg = "#{msg} (المحادثات: #{ids.map { |i| "##{i}" }.join('، ')})" if Array(params[:ids]).size > 1
          return [blocked.first[1][0], msg, :unprocessable_entity]
        end
      end
      nil
    rescue StandardError => e
      Rails.logger.warn("[qaydao-guard] bulk check failed -> allow: #{e.class} #{e.message}")
      nil
    end
  end

  # -- model backstop --------------------------------------------------------
  module ConversationGuard

    def qaydao_action_guard_validation
      user = Current.user
      return unless QaydaoActionGuards.human?(user)

      if will_save_change_to_assignee_id? && assignee_id_in_database.to_i.positive? &&
         assignee_id.to_i <= 0 && assignee_agent_bot_id.blank? && !QaydaoActionGuards.may_unassign?(user)
        QaydaoActionGuards.log_refusal(:unassign_forbidden_model, user, display_id)
        errors.add(:base, QaydaoActionGuards::UNASSIGN_MSG)
      end

      if will_save_change_to_status? && snoozed?
        refusal = QaydaoActionGuards.snooze_refusal(user, self, snoozed_until.present?)
        if refusal
          QaydaoActionGuards.log_refusal("#{refusal[0]}_model", user, display_id)
          errors.add(:base, refusal[1])
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[qaydao-guard] model check failed conv ##{id} -> allow: #{e.class} #{e.message}")
    end
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  Rails.application.config.to_prepare do
    begin
      ac = 'Api::V1::Accounts::Conversations::AssignmentsController'.safe_constantize
      ac.prepend(QaydaoActionGuards::AssignmentsGuard) if ac && !(ac < QaydaoActionGuards::AssignmentsGuard)

      cc = 'Api::V1::Accounts::ConversationsController'.safe_constantize
      cc.prepend(QaydaoActionGuards::ToggleStatusGuard) if cc && !(cc < QaydaoActionGuards::ToggleStatusGuard)

      bc = 'Api::V1::Accounts::BulkActionsController'.safe_constantize
      bc.prepend(QaydaoActionGuards::BulkGuard) if bc && !(bc < QaydaoActionGuards::BulkGuard)

      if defined?(::Conversation) && !(::Conversation < QaydaoActionGuards::ConversationGuard)
        ::Conversation.include(QaydaoActionGuards::ConversationGuard)
        ::Conversation.validate :qaydao_action_guard_validation, on: :update
      end

      Rails.logger.info("[qaydao-patch] agent action guards applied (unassign allowed: #{QaydaoActionGuards.allowed_unassign_emails.join(',')}; no-snooze labels: #{QaydaoActionGuards.no_snooze_labels.join(',')})")
    rescue StandardError => e
      Rails.logger.error("[qaydao-patch] agent action guards NOT applied: #{e.class} #{e.message}")
    end
  end
end
