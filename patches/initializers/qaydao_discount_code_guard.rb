# QAYDAO 2026-07-05 — Discount-code guard for Captain AI responses.
#
# REQUIREMENT (Omar):
#   Permanently stop QAYDAO AI from sending ANY discount code / coupon / promo
#   offer to a customer — even code "AI", "F5", or any other, even if the
#   customer asks directly. When a discount is requested (or the AI reply would
#   contain one), the AI must reply ONLY with the fixed Arabic redirect text and
#   the conversation must be handed off to a human agent.
#
# SCOPE (deterministic, independent of the LLM):
#   * Applies ONLY to AI (Captain) generated replies — this guard runs inside
#     Captain::Assistant::AgentRunnerService#process_agent_result, which never
#     sees human-agent messages.
#   * Does NOT block price display (ريال) or product links (qaydao.com/-/p...).
#   * Logs `discount_code_ai_blocked` whenever it intercepts.
#   * Fail-safe: on ANY error, block + hand off (never leak a code).
#
# Bind-mounted on web + sidekiq_captain; survives restarts/upgrades.

Rails.application.config.to_prepare do
  next unless defined?(Captain::Assistant::AgentRunnerService)

  klass = Captain::Assistant::AgentRunnerService
  next if klass.included_modules.map(&:name).include?('QaydaoDiscountCodeGuard')

  mod = Module.new do
    def self.name = 'QaydaoDiscountCodeGuard'

    QAYDAO_DISCOUNT_REDIRECT_TEXT =
      'سيتم تحويلك إلى أحد موظفي خدمة العملاء لمساعدتك وتزويدك بالعروض أو الخصومات المتاحة لدينا إن وجدت.'

    # Note: 'تصعيد' is defined as QAYDAO_ESCALATION_LABEL in sibling initializers.
    # We reference the literal locally to avoid constant-redefinition warnings and
    # load-order coupling.
    QAYDAO_DISCOUNT_ESCALATION_LABEL = 'تصعيد'

    # Intent: customer asking for a discount/coupon/offer (Arabic + English).
    QAYDAO_DISCOUNT_INTENT = /
      كود\s*خصم | كوبون | خصم | خصومات | عرض | عروض | تخفيض | تخفيضات |
      كوبونات | بروموكود | \bpromo\b | \bcoupon\b | \bdiscount\b | \bvoucher\b | \boffer\b
    /ix.freeze

    # A discount CODE actually present in an AI reply. Deliberately narrow so it
    # does NOT match prices ("1050 ريال") or product links ("qaydao.com/-/p281483017").
    # Matches: explicit coupon/discount words + a token, "code: X", "الكود X",
    # and standalone code-like tokens AI/F5 or CAPS+DIGITS combos.
    QAYDAO_CODE_IN_REPLY = /
      (?:كود|كوبون|بروموكود|promo\s*code|coupon\s*code|discount\s*code|الكود)\s*[:：\-]?\s*[A-Za-z0-9]{2,} |
      \b(?:AI|F5)\b |
      \b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*[0-9])[A-Z0-9]{4,}\b
    /x.freeze

    def process_agent_result(result)
      response = super

      text = response.is_a?(Hash) ? response['response'].to_s : response.to_s

      # Only act on a real customer-facing text reply (skip control tokens like
      # 'conversation_handoff' which are not shown to the customer).
      return response if text.blank? || text == 'conversation_handoff'

      last_user = qaydao_last_user_text
      intent    = last_user.present? && last_user.match?(QAYDAO_DISCOUNT_INTENT)
      leaks     = qaydao_reply_leaks_code?(text)

      return response unless intent || leaks

      reason = leaks ? 'ai_reply_contained_code' : 'customer_asked_for_discount'
      qaydao_log_discount_block(reason, text)
      qaydao_apply_escalation_label

      if response.is_a?(Hash)
        response['response'] = QAYDAO_DISCOUNT_REDIRECT_TEXT
        response['handoff_tool_called'] = true
        response['reasoning'] = "discount_code_ai_blocked (#{reason})"
        response
      else
        {
          'response' => QAYDAO_DISCOUNT_REDIRECT_TEXT,
          'handoff_tool_called' => true,
          'reasoning' => "discount_code_ai_blocked (#{reason})"
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[qaydao-discount-guard] error -> BLOCK + handoff (fail-safe): #{e.message}")
      {
        'response' => QAYDAO_DISCOUNT_REDIRECT_TEXT,
        'handoff_tool_called' => true,
        'reasoning' => 'discount_code_ai_blocked (guard_error_failsafe)'
      }
    end

    private

    def qaydao_reply_leaks_code?(text)
      # Strip product links + prices first so they can never trigger a code match.
      cleaned = text.dup
      cleaned.gsub!(%r{https?://\S*qaydao\.com/\S+}i, ' ')          # product/store links
      cleaned.gsub!(/\d[\d,]*\s*(?:ريال|ر\.?س|SAR)/i, ' ')          # prices
      cleaned.match?(QAYDAO_CODE_IN_REPLY)
    end

    def qaydao_last_user_text
      hist = @conversation&.messages
      return '' unless hist

      msg = hist.where(message_type: :incoming, private: false).order(created_at: :desc).first
      msg&.content.to_s
    rescue StandardError
      ''
    end

    def qaydao_apply_escalation_label
      return unless @conversation

      unless @conversation.label_list.include?(QAYDAO_DISCOUNT_ESCALATION_LABEL)
        @conversation.add_labels([QAYDAO_DISCOUNT_ESCALATION_LABEL])
      end
    rescue StandardError => e
      Rails.logger.warn("[qaydao-discount-guard] label apply failed conv ##{@conversation&.id}: #{e.message}")
    end

    def qaydao_log_discount_block(reason, original_text)
      Rails.logger.info(
        "[discount_code_ai_blocked] conv=##{@conversation&.id} reason=#{reason} " \
        "assistant_id=#{@assistant&.id} original=#{original_text.to_s[0, 200].inspect}"
      )
    end
  end

  klass.prepend(mod)
  Rails.logger.info('[qaydao-patch] discount-code guard applied (AI never sends discount/coupon codes)')
end
