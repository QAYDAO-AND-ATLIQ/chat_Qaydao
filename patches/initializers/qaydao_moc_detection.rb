# QAYDAO 2026-11-04 — Ministry of Commerce (وزارة التجارة) detection (approved by Rami, staging first).
#
# WHY: official MoC monitors write to the store on WhatsApp/widget (≈16 conversations
# in Oct 2026) and QAYDAO AI answered them with generic text; customers who
# threaten/mention a ministry complaint (≈180 conversations / 30 days) were not
# flagged either.
#
# WHAT (on every incoming, public contact message — in the process that creates
# the message: web for widget/API, sidekiq for WhatsApp/Instagram webhooks):
#   (a) OFFICIAL monitor (QaydaoMocMatcher :official, or the conversation already
#       carries the label):
#         label `وزارة_التجارة` (created if missing), priority urgent,
#         assign to QAYDAO_MOC_OWNER_EMAIL (default maher@qaydao.com) when that
#         user can be assigned in the inbox (Chatwoot rule: inbox member OR account
#         administrator) — otherwise a private note explains (inbox membership is
#         NEVER added automatically); a later team change by automation/macro does
#         not drop him (KeepOwnerOnTeamChange),
#         private note «🔴 رسالة من مراقب وزارة التجارة …»,
#         Captain bypass: bot_handoff! and the message-template hooks (Captain
#         scheduling, greeting, out-of-office, email-collect) are skipped, so no
#         canned/AI text ever reaches a monitor. A ResponseBuilderJob guard keeps
#         Captain silent on any conversation carrying the label.
#   (b) THREAT (customer mentions/threatens a ministry complaint):
#         label `تهديد_بلاغ`, priority urgent, assignee kept, owner added as a
#         conversation participant (watcher), private note. Captain is NOT bypassed.
#   Idempotent: label/priority/assignment/note at most once per conversation per
#   24h per class (row lock on the conversation + existing-note check).
#   For the external alert scanner the first matching message is recorded once in
#   conversations.custom_attributes:
#       moc_official_first_at / moc_official_first_message_id
#       moc_threat_first_at   / moc_threat_first_message_id   (ISO-8601 UTC)
#   Nothing is persisted outside the Chatwoot DB. Kill switch: QAYDAO_MOC_DETECTION=off.
#   Fail-open: any error is logged and the normal flow continues.
#
# Bind-mount on web + sidekiq + sidekiq_captain.

module QaydaoMocMatcher
  module_function

  def normalize(text)
    s = text.to_s.dup.force_encoding('UTF-8').scrub('')
    s = s.gsub(/[\p{Mn}\p{Cf}]/, '').delete('ـ')        # tashkeel, Quranic marks, zero-width/bidi chars, tatweel
    s = s.tr('أإآٱ', 'اااا').tr('ة', 'ه').tr('ى', 'ي')
    s.gsub(/\s+/, ' ').downcase.strip
  end

  NB  = '(?<!\p{L})'.freeze                    # no letter right before (Arabic-safe word start)
  MOC = 'وزا?ر?ه\s*ال?ت[جح]ار'.freeze          # وزارة التجارة (+ typos: وزاه التجاره، وزاره التحاره، وزاره تجاره)

  OFFICIAL = [
    /#{NB}(?:معك|معاك|معكم)(?:\s+\S+){0,3}?\s+(?:من|مراقب)\s+(?:ال)?#{MOC}/, # «معك فلان من وزارة التجارة»
    /#{NB}(?:معك|معاك|معكم)\s+(?:من\s+)?(?:ال)?#{MOC}/,                       # «معكم وزارة التجارة»
    /#{NB}وردنا\s+(?:بلاغ|شكوي)/,                                             # «وردنا بلاغ»
    /تزويدنا\s+بالافاده/,                                                     # «تزويدنا بالإفادة»
    /#{NB}رقم\s+البلاغ/,                                                      # «رقم البلاغ»
    /#{NB}اداره\s+(?:المتابعه|الرقابه|المتاجر\s+الالكترونيه)/,               # «إدارة المتابعة / الرقابة / المتاجر الإلكترونية»
    /#{NB}مراقب(?:ين)?\s+(?:من\s+)?(?:ال)?وزاره/,                             # «مراقب (من) الوزارة»
    /#{NB}(?:يوجد|ورود)\s+بلاغ/,
    /#{NB}احاله\s+البلاغ/,
    /#{NB}البلاغ\s+المصعد/,
    /#{NB}بلاغ\s+(?:مقدم|المستهلك)/,
    /#{NB}تم\s+(?:مراسلتكم|مخاطبتكم)[^!؟?\n]{0,90}?بلاغ/,
    /#{NB}بخصوص\s+(?:ال)?بلاغ\s+(?:علي|ضد)\s+متجر/
  ].freeze

  THREAT = [
    /#{MOC}/,                                                                 # any mention of وزارة التجارة
    /(?:شك|شتك|بلاغ|رفع|بلغ)[^.!؟?\n]{0,25}?#{NB}(?:لل|ل|ال)وزاره(?!\s*ال(?:ماليه|صحه|داخليه))/, # «بشتكيكم للوزارة»
    /#{NB}(?:ال)?بلاغ\s+(?:ال)?تجاري/,                                        # «بلاغ تجاري» (MoC complaints app)
    /#{NB}حمايه\s+المستهلك/,
    /#{NB}(?:ارفع|برفع|بارفع|سارفع|حرفع|نرفع|رفع|رفعت|اقدم|بقدم|ساقدم|حقدم|تقديم|قدمت|باشرت)\s+(?:\S+\s+){0,2}?(?:ال|ل|لل|ف|ب)?بلاغ/ # «برفع بلاغ»
  ].freeze

  # "ترفع لي بلاغ" = the customer asks US to open an internal ticket — not a threat
  THREAT_EXCLUDE = [/(?:ترفع|ترفعون|ترفعين|ترفعو)\s+لي\s+بلاغ/].freeze

  # => :official, :threat or nil
  def classify(text)
    n = normalize(text)
    return nil if n.empty?
    return :official if OFFICIAL.any? { |r| n.match?(r) }

    rules = THREAT_EXCLUDE.any? { |r| n.match?(r) } ? THREAT[0..3] : THREAT
    rules.any? { |r| n.match?(r) } ? :threat : nil
  end
end

module QaydaoMocDetection
  LABEL_OFFICIAL = 'وزارة_التجارة'.freeze
  LABEL_THREAT   = 'تهديد_بلاغ'.freeze
  NOTE_OFFICIAL  = '🔴 رسالة من مراقب وزارة التجارة — الرد خلال ساعة عمل برد فعلي ومستندات، يمنع النص الجاهز'.freeze
  NOTE_THREAT    = '🟠 العميل يذكر بلاغاً/شكوى لوزارة التجارة — عالج طلبه الآن برد فعلي وحل واضح، يمنع النص الجاهز'.freeze
  WINDOW = 24 * 3600 # seconds

  CLASS_CONFIG = {
    official: { label: LABEL_OFFICIAL, note: NOTE_OFFICIAL, color: '#DC2626',
                description: 'مراقب وزارة التجارة — رد خلال ساعة عمل (تلقائي)' },
    threat:   { label: LABEL_THREAT, note: NOTE_THREAT, color: '#EA580C',
                description: 'عميل يذكر/يهدد ببلاغ لوزارة التجارة (تلقائي)' }
  }.freeze

  module_function

  def enabled?
    ENV.fetch('QAYDAO_MOC_DETECTION', 'on').to_s.downcase != 'off'
  end

  def owner_email
    ENV.fetch('QAYDAO_MOC_OWNER_EMAIL', 'maher@qaydao.com').to_s.strip.downcase
  end

  # Returns :official / :threat / nil. Never raises.
  def process(message)
    return nil unless enabled?
    return nil unless message.incoming? && !message.private?

    conversation = message.conversation
    return nil if conversation.nil?

    klass = conversation.label_list.include?(LABEL_OFFICIAL) ? :official : QaydaoMocMatcher.classify(message.content)
    return nil if klass.nil?

    cfg = CLASS_CONFIG[klass]
    ensure_label!(conversation.account, cfg)
    owner = conversation.account.users.find_by('LOWER(users.email) = ?', owner_email)

    noted = false
    conversation.with_lock do
      record_first_seen!(conversation, klass, message)
      conversation.add_labels([cfg[:label]]) unless conversation.label_list.include?(cfg[:label])
      unless recent_note?(conversation, cfg[:note])
        apply_actions!(conversation, klass, owner)
        create_note!(conversation, note_text(conversation, klass, owner))
        noted = true
      end
    end

    if klass == :official && conversation.reload.pending?
      conversation.bot_handoff!
      Rails.logger.info("[qaydao-moc] conv ##{conversation.id} bot_handoff! (official monitor — Captain bypassed)")
    end
    Rails.logger.info("[qaydao-moc] conv ##{conversation.id} display=#{conversation.display_id} msg=#{message.id} class=#{klass} noted=#{noted}")
    klass
  rescue StandardError => e
    Rails.logger.warn("[qaydao-moc] conv ##{message&.conversation_id} msg=#{message&.id} failed -> continue (fail-open): #{e.class} #{e.message}")
    nil
  end

  def ensure_label!(account, cfg)
    return if account.labels.exists?(title: cfg[:label])

    account.labels.create!(title: cfg[:label], color: cfg[:color], description: cfg[:description], show_on_sidebar: true)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    Rails.logger.info("[qaydao-moc] label #{cfg[:label]} not created (#{e.message}) — tagging anyway")
  end

  def record_first_seen!(conversation, klass, message)
    attrs = (conversation.custom_attributes || {}).dup
    key = "moc_#{klass}_first_at"
    return if attrs[key].present?

    attrs[key] = message.created_at.utc.iso8601
    attrs["moc_#{klass}_first_message_id"] = message.id
    conversation.update!(custom_attributes: attrs)
  end

  def recent_note?(conversation, note)
    conversation.messages.where(private: true).where('created_at > ?', Time.now.utc - WINDOW)
                .where('content LIKE ?', "#{note[0, 40]}%").exists?
  end

  def assignable?(conversation, user)
    user.present? && conversation.inbox.assignable_agents.include?(user)
  end

  def apply_actions!(conversation, klass, owner)
    attrs = {}
    attrs[:priority] = :urgent unless conversation.priority.to_s == 'urgent'
    attrs[:assignee] = owner if klass == :official && assignable?(conversation, owner) && conversation.assignee_id != owner.id
    conversation.update!(attrs) if attrs.any?

    return unless klass == :threat && assignable?(conversation, owner)

    conversation.conversation_participants.find_or_create_by!(user_id: owner.id)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.info("[qaydao-moc] conv ##{conversation.id} watcher not added: #{e.message}")
  end

  def note_text(conversation, klass, owner)
    lines = [CLASS_CONFIG[klass][:note]]
    if owner.nil?
      lines << "⚠️ لم يُعثر على حساب المسؤول (#{owner_email}) — لم يُسند/يُضف كمتابع تلقائياً."
    elsif !assignable?(conversation, owner)
      lines << "⚠️ #{owner.available_name} (#{owner.email}) ليس عضواً في هذا الصندوق ولا مديراً للحساب، فلم #{klass == :official ? 'تُسند المحادثة إليه' : 'يُضف كمتابع'} تلقائياً — إضافته للصندوق قرار من الإدارة."
    elsif klass == :official
      lines << "تم إسناد المحادثة إلى #{owner.available_name} وإيقاف QAYDAO AI فيها."
    else
      lines << "أُضيف #{owner.available_name} كمتابع للمحادثة."
    end
    lines.join("\n")
  end

  def create_note!(conversation, content)
    conversation.messages.create!(
      message_type: :outgoing, private: true, content: content,
      account_id: conversation.account_id, inbox_id: conversation.inbox_id
    )
  end

  module MessageHook
    private

    # Runs inside Message#execute_after_create_commit_callbacks, right before the
    # template hooks that schedule Captain. Official monitor -> skip them entirely.
    def execute_message_template_hooks
      return super unless incoming? && !private?

      return if QaydaoMocDetection.process(self) == :official

      super
    end
  end

  # Team automation (e.g. rule "assign team 2" on conversation_opened/created) runs
  # Chatwoot's ensure_assignee_is_from_team, which would drop the MoC owner because
  # he is not a member of the support team. Keep him on official conversations only.
  module KeepOwnerOnTeamChange
    private

    def validate_current_assignee_team
      return if qaydao_moc_owner_assigned?

      super
    end

    def qaydao_moc_owner_assigned?
      assignee.present? && assignee.email.to_s.downcase == QaydaoMocDetection.owner_email &&
        label_list.include?(QaydaoMocDetection::LABEL_OFFICIAL)
    rescue StandardError
      false
    end
  end

  module CaptainGuard
    def perform(conversation, assistant)
      if qaydao_moc_official?(conversation)
        Rails.logger.info("[qaydao-moc] Captain silent on conv ##{conversation.id} (label #{QaydaoMocDetection::LABEL_OFFICIAL})")
        conversation.bot_handoff! if conversation.reload.pending?
        return
      end
      super
    end

    private

    def qaydao_moc_official?(conversation)
      conversation.present? && conversation.reload.label_list.include?(QaydaoMocDetection::LABEL_OFFICIAL)
    rescue StandardError => e
      Rails.logger.warn("[qaydao-moc] captain guard check failed conv ##{conversation&.id} -> Captain runs: #{e.message}")
      false
    end
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  Rails.application.config.to_prepare do
    begin
      if defined?(::Message) && !(::Message < QaydaoMocDetection::MessageHook)
        ::Message.prepend(QaydaoMocDetection::MessageHook)
      end
      if defined?(::Conversation) && !(::Conversation < QaydaoMocDetection::KeepOwnerOnTeamChange)
        ::Conversation.prepend(QaydaoMocDetection::KeepOwnerOnTeamChange)
      end
      job = 'Captain::Conversation::ResponseBuilderJob'.safe_constantize
      job.prepend(QaydaoMocDetection::CaptainGuard) if job && !(job < QaydaoMocDetection::CaptainGuard)
      Rails.logger.info("[qaydao-patch] MoC detection applied (owner=#{QaydaoMocDetection.owner_email}, enabled=#{QaydaoMocDetection.enabled?}, captain_guard=#{job.present?})")
    rescue StandardError => e
      Rails.logger.error("[qaydao-patch] MoC detection NOT applied: #{e.class} #{e.message}")
    end
  end
end
