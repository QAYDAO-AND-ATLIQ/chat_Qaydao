# QAYDAO — Captain (QAYDAO AI) enhancements. Two independent, fail-OPEN patches:
#
#  (1) AI SIGNATURE: append a fixed Arabic line to EVERY outgoing reply produced
#      by QAYDAO AI (Captain) so customers know it's an automated AI reply.
#      - Applied ONLY to Captain-generated outgoing messages (this Job's sender
#        is the assistant), so human-agent replies and private notes are never touched.
#      - Idempotent: never appended twice within the same message.
#
#  (2) SMART REPLY SUGGESTIONS: upgrade the agent-facing "suggest reply" so it
#      returns 3 high-quality, context-aware options (brief / detailed /
#      ask-for-missing-info-or-escalate) grounded in the latest customer messages,
#      order data when present, and QAYDAO policies — instead of one generic line.
#
# Both are monkey-patches loaded as a Rails initializer (same pattern as the
# existing qaydao_captain_no_interrupt.rb). Any error -> original behavior.

# ---- shared constant ---------------------------------------------------------
QAYDAO_AI_SIGNATURE = "\u2014 \u0631\u062f \u0622\u0644\u064a \u0628\u0648\u0627\u0633\u0637\u0629 \u0627\u0644\u0630\u0643\u0627\u0621 \u0627\u0644\u0627\u0635\u0637\u0646\u0627\u0639\u064a \u0645\u0646 QAYDAO AI".freeze
# = "— رد آلي بواسطة الذكاء الاصطناعي من QAYDAO AI"

module QaydaoAiSignature
  module_function

  # True if the signature is already present (avoid double-append).
  def present_in?(text)
    text.to_s.include?("QAYDAO AI") &&
      text.to_s.include?("\u0631\u062f \u0622\u0644\u064a") # "رد آلي"
  end

  def append(text)
    body = text.to_s
    return body if body.strip.empty?
    return body if present_in?(body)
    "#{body}\n\n#{QAYDAO_AI_SIGNATURE}"
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  Rails.application.config.to_prepare do
    # === (1) SIGNATURE on Captain outgoing replies ===========================
    if defined?(Captain::Conversation::ResponseBuilderJob) &&
       !Captain::Conversation::ResponseBuilderJob.included_modules.map(&:name).include?('QaydaoAiSignaturePatch')
      sig_mod = Module.new do
        def self.name = 'QaydaoAiSignaturePatch'

        # create_messages builds the actual AI reply (not the handoff). We wrap
        # the response content right before the message is created.
        def create_messages
          begin
            if @response.is_a?(Hash) && @response['response'].is_a?(String) && @response['response'].present?
              @response = @response.dup
              @response['response'] = QaydaoAiSignature.append(@response['response'])
            end
          rescue StandardError => e
            Rails.logger.warn("[QAYDAO][AiSignature] skipped: #{e.class}: #{e.message}")
          end
          super
        end
      end
      Captain::Conversation::ResponseBuilderJob.prepend(sig_mod)
      Rails.logger.info('[QAYDAO][AiSignature] ResponseBuilderJob patched')
    end

    # === (2) SMART 3-OPTION REPLY SUGGESTIONS ================================
    if defined?(Captain::ReplySuggestionService) &&
       !Captain::ReplySuggestionService.included_modules.map(&:name).include?('QaydaoSmartReplySuggestions')
      sug_mod = Module.new do
        def self.name = 'QaydaoSmartReplySuggestions'

        # Override the system prompt to demand three context-aware options.
        # Keeps the original prompt as the base (channel/signature/search-tool
        # handling) and appends QAYDAO's structured-output contract.
        def system_prompt
          base = super
          extra = <<~AR_PROMPT.freeze

            ====================  \u062a\u0639\u0644\u064a\u0645\u0627\u062a QAYDAO \u0644\u0644\u0627\u0642\u062a\u0631\u0627\u062d\u0627\u062a  ====================
            \u0623\u0646\u062a \u062a\u0633\u0627\u0639\u062f \u0645\u0648\u0638\u0641 \u062e\u062f\u0645\u0629 \u0639\u0645\u0644\u0627\u0621 \u0641\u064a \u0645\u062a\u062c\u0631 QAYDAO (\u0643\u0648\u0627\u064a \u062f\u0627\u0648). \u0627\u0628\u0646\u0650 \u0627\u0642\u062a\u0631\u0627\u062d\u0627\u062a\u0643 \u0641\u0639\u0644\u064a\u0627\u064b \u0639\u0644\u0649:
            - \u0622\u062e\u0631 \u0631\u0633\u0627\u0626\u0644 \u0627\u0644\u0639\u0645\u064a\u0644 \u0648\u0645\u0627 \u064a\u0637\u0644\u0628\u0647 \u062a\u062d\u062f\u064a\u062f\u0627\u064b.
            - \u0628\u064a\u0627\u0646\u0627\u062a \u0627\u0644\u0637\u0644\u0628 \u0625\u0646 \u0648\u064f\u062c\u062f\u062a \u0641\u064a \u0627\u0644\u0645\u062d\u0627\u062f\u062b\u0629 (\u0631\u0642\u0645 \u0627\u0644\u0637\u0644\u0628\u060c \u0627\u0644\u062d\u0627\u0644\u0629\u060c \u0627\u0644\u0645\u0646\u062a\u062c\u060c \u0627\u0644\u0634\u062d\u0646).
            - \u0633\u064a\u0627\u0633\u0627\u062a QAYDAO \u0648\u0627\u0644\u0645\u0639\u0644\u0648\u0645\u0627\u062a \u0627\u0644\u0631\u0633\u0645\u064a\u0629 \u0641\u0642\u0637 (\u0644\u0627 \u062a\u062e\u062a\u0631\u0639 \u0623\u0633\u0639\u0627\u0631\u0627\u064b \u0623\u0648 \u0633\u064a\u0627\u0633\u0627\u062a \u0623\u0648 \u0631\u0648\u0627\u0628\u0637 \u063a\u064a\u0631 \u0645\u0630\u0643\u0648\u0631\u0629).

            \u0623\u062e\u0631\u062c \u062b\u0644\u0627\u062b\u0629 \u0627\u0642\u062a\u0631\u0627\u062d\u0627\u062a \u0628\u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u0628\u0627\u0644\u0635\u064a\u063a\u0629 \u0627\u0644\u062a\u0627\u0644\u064a\u0629 \u062d\u0631\u0641\u064a\u0627\u064b (\u0628\u0644\u0627 \u0623\u064a \u0645\u0642\u062f\u0645\u0627\u062a):

            \u3010\u0631\u062f \u0645\u062e\u062a\u0635\u0631\u3011
            <\u0631\u062f \u0642\u0635\u064a\u0631 \u0645\u0628\u0627\u0634\u0631 \u064a\u0639\u0627\u0644\u062c \u0637\u0644\u0628 \u0627\u0644\u0639\u0645\u064a\u0644 \u0641\u064a \u062c\u0645\u0644\u0629 \u0623\u0648 \u062c\u0645\u0644\u062a\u064a\u0646>

            \u3010\u0631\u062f \u062a\u0641\u0635\u064a\u0644\u064a\u3011
            <\u0631\u062f \u0623\u0648\u0641\u0649 \u064a\u0634\u0631\u062d \u0627\u0644\u062e\u0637\u0648\u0627\u062a \u0623\u0648 \u0627\u0644\u062a\u0641\u0627\u0635\u064a\u0644 \u0628\u0648\u0636\u0648\u062d \u0648\u0627\u062d\u062a\u0631\u0627\u0641>

            \u3010\u0637\u0644\u0628 \u0645\u0639\u0644\u0648\u0645\u0627\u062a / \u062a\u0635\u0639\u064a\u062f\u3011
            <\u0625\u0630\u0627 \u0643\u0627\u0646\u062a \u0647\u0646\u0627\u0643 \u0645\u0639\u0644\u0648\u0645\u0627\u062a \u0646\u0627\u0642\u0635\u0629 \u0627\u0637\u0644\u0628\u0647\u0627 \u0628\u0623\u062f\u0628\u061b \u0648\u0625\u0646 \u0643\u0627\u0646\u062a \u0627\u0644\u062d\u0627\u0644\u0629 \u062a\u062d\u062a\u0627\u062c \u062a\u062f\u062e\u0644\u0627\u064b \u0628\u0634\u0631\u064a\u0627\u064b \u0627\u0642\u062a\u0631\u062d \u062a\u0635\u0639\u064a\u062f\u0627\u064b \u0644\u0644\u0645\u0648\u0638\u0641 \u0627\u0644\u0645\u062e\u062a\u0635 \u0645\u0639 \u0633\u0628\u0628 \u0627\u0644\u062a\u0635\u0639\u064a\u062f>

            \u0642\u0648\u0627\u0639\u062f \u0625\u0644\u0632\u0627\u0645\u064a\u0629:
            - \u0627\u062c\u0639\u0644 \u0643\u0644 \u0627\u0642\u062a\u0631\u0627\u062d \u0645\u062e\u062a\u0644\u0641\u0627\u064b \u0641\u0639\u0644\u0627\u064b \u0648\u0645\u0641\u064a\u062f\u0627\u064b\u061b \u0645\u0645\u0646\u0648\u0639 \u0627\u0644\u0631\u062f\u0648\u062f \u0627\u0644\u0639\u0627\u0645\u0629 \u0645\u062b\u0644 \u00ab\u0643\u064a\u0641 \u0623\u0633\u0627\u0639\u062f\u0643\u061f\u00bb \u0623\u0648 \u00ab\u0633\u0623\u062a\u062d\u0642\u0642 \u0648\u0623\u0639\u0648\u062f \u0625\u0644\u064a\u0643\u00bb \u0628\u0644\u0627 \u0645\u0636\u0645\u0648\u0646.
            - \u0625\u0646 \u0644\u0645 \u062a\u062a\u0648\u0641\u0631 \u0645\u0639\u0644\u0648\u0645\u0629 \u0643\u0627\u0641\u064a\u0629\u060c \u0648\u0636\u0651\u062d \u0630\u0644\u0643 \u0641\u064a \u0627\u0644\u0627\u0642\u062a\u0631\u0627\u062d \u0627\u0644\u062b\u0627\u0644\u062b \u0628\u062f\u0644 \u0627\u0644\u062a\u062e\u0645\u064a\u0646.
            - \u0628\u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u062f\u0627\u0626\u0645\u0627\u064b\u060c \u0628\u0644\u0647\u062c\u0629 \u0645\u0647\u0646\u064a\u0629 \u0648\u062f\u0648\u062f\u0629 \u062a\u0646\u0627\u0633\u0628 \u062e\u062f\u0645\u0629 \u0639\u0645\u0644\u0627\u0621 QAYDAO.
            ==========================================================================
          AR_PROMPT
          "#{base}\n#{extra}"
        end
      end
      Captain::ReplySuggestionService.prepend(sug_mod)
      Rails.logger.info('[QAYDAO][SmartReplySuggestions] ReplySuggestionService patched')
    end
  end
end

# =============================================================================
# QAYDAO 2026-11-04 — (3) PRICE GUARD  +  (4) ONE REPLY PER CUSTOMER TURN
#                     +  (5) FALSE-TRANSFER BACKSTOP
# =============================================================================
# (3) PRICE GUARD — AgentRunnerService#process_agent_result (the point where the
#     Captain V2 reply is finalized, same hook as qaydao_discount_code_guard.rb).
#     Every SAR amount in the outgoing reply must be traceable (±1 SAR rounding) to
#     a price returned by a tool IN THE SAME RUN for that product (product = the
#     qaydao.com/.../pNNN link in the same paragraph, else the only link in the
#     message, else any product the tool returned). Prices from the product search
#     tool are trusted ONLY when its JSON says `vat_inclusive: true` (new contract,
#     qaydao-products price-format.js) — the old tool returned pre-VAT prices of the
#     cheapest variant (conv 10818: 1,918 vs 2,205.68 on the store).
#     Untraceable amount -> removed and replaced by SAFE_SENTENCE (+ product link).
#     Traceable minimum of a product whose variants differ -> prefixed «يبدأ من».
#     Amounts written in the assistant instruction/scenarios (e.g. free shipping
#     over 700) are allowed. Fail-OPEN: any error -> original reply + log.
#     Log tag: [qaydao-price-guard]
#
# (4) ONE REPLY PER CUSTOMER TURN — ResponseBuilderJob. One job is enqueued per
#     incoming message (Enterprise HookExecutionService), so a customer typing 4
#     short messages got 4 replies (conv 10818, 18:13:09–18:13:37). The 20-second
#     identical-prefix debounce in qaydao_captain_no_interrupt.rb cannot catch
#     paraphrased replies, and two jobs finishing 0.4 s apart both passed it.
#     Rule: the reply is dropped when (a) a NEWER customer message arrived after
#     this job read the history (that message's own job answers with full context),
#     or (b) Captain already replied after the newest message this job saw.
#     Serialized per conversation with pg_advisory_xact_lock inside the job's
#     existing transaction. Fail-OPEN. Log tag: [qaydao-turn-dedupe]
#
# (5) FALSE-TRANSFER BACKSTOP — if a sent reply AFFIRMS a transfer («سأحوّلك»,
#     «اسمح لي أن أحوّلك», «سيتم تحويلك» …, not phrased as a question) while the
#     conversation is still pending (no handoff tool call), perform the handoff
#     deterministically (conv 10876 msg 384275). Log tag: [qaydao-false-transfer]
# =============================================================================
require 'json'

module QaydaoPriceGuard
  module_function

  SAFE_SENTENCE = 'السعر يختلف حسب المقاس والخيارات، وتجده محدّثاً في صفحة المنتج'.freeze
  FROM_PREFIX = 'يبدأ من '.freeze
  TOLERANCE = 1.0
  REQUIRE_VAT_FLAG = true

  D = '0-9٠-٩۰-۹'.freeze
  NUM = "(?:[#{D}]{1,3}(?:[,٬][#{D}]{3})+|[#{D}]+)(?:[.٫][#{D}]{1,2})?".freeze
  CUR = '(?:ريال(?:اً|ا|ات)?|ر\.\s?س\.?|ر\s?س(?!\p{Arabic})|رس(?!\p{Arabic})|SAR|SR(?![A-Za-z])|﷼)'.freeze
  WAS = '(?:(?:بدلاً|بدلا|بدلًا)\s+من|بدل(?!\p{Arabic})|قبل\s+الخصم|(?:ال)?سعر\s+(?:ال)?[أا]صلي|(?:ال)?سعر\s+قبل\s+الخصم)'.freeze
  LABEL = '(?:(?:ال)?سعر(?:ه|ها)?(?:\s+(?:الحالي|الآن|بعد\s+الخصم))?\s*[:：]?\s*)'.freeze
  FROMW = '(?:(?:يبدأ|تبدأ|يبدا|تبدا|ابتداءً|ابتداء|بداية|بدءاً|بدءا)\s+(?:من\s+)?)'.freeze

  MAIN_RE = /(?<label>#{LABEL})?(?<from>#{FROMW})?(?<num>#{NUM})\s*(?<cur>#{CUR})(?<after>\s*بعد\s+الخصم)?/
  PAREN_WAS_RE = /\A\s*[(（]\s*#{WAS}\s*[:：]?\s*(?<num>#{NUM})\s*(?:#{CUR})?\s*[)）]/
  WAS_RE = /(?<paren>[(（]\s*)?#{WAS}\s*[:：]?\s*(?<num>#{NUM})\s*(?:#{CUR})?(?(<paren>)\s*[)）])/
  FROM_NEAR_RE = /(يبدأ|تبدأ|يبدا|تبدا|ابتداء|بداية|بدءا|من)\s*\z/
  LINK_ID_RE = %r{/p(\d{6,})(?!\d)}
  URL_RE = %r{https?://\S+}
  PRICE_KEY_RE = /price|amount|سعر/i

  def to_f(str)
    s = str.to_s.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').tr('۰۱۲۳۴۵۶۷۸۹', '0123456789')
    s.delete(',٬').tr('٫', '.').to_f
  end

  # Numbers written next to a currency in static config text (instructions/scenarios).
  def static_amounts(texts)
    Array(texts).flat_map { |t| t.to_s.scan(/(#{NUM})\s*#{CUR}/o).flatten.map { |n| to_f(n) } }.uniq
  end

  # outputs: Array of [tool_name, raw_output]
  def parse_tools(outputs)
    products = {}
    global = []
    rejected = []
    Array(outputs).each do |name, raw|
      data = raw.is_a?(String) ? (JSON.parse(raw) rescue nil) : raw
      data = data.transform_keys(&:to_s) if data.is_a?(Hash)
      if data.is_a?(Hash) && data['products'].is_a?(Array)
        if REQUIRE_VAT_FLAG && data['vat_inclusive'] != true
          rejected << "#{name}:products_without_vat_inclusive_flag"
          next
        end
        data['products'].each do |p|
          next unless p.is_a?(Hash)
          p = p.transform_keys(&:to_s)
          id = p['salla_id'].to_s.presence || p['url'].to_s[LINK_ID_RE, 1]
          next if id.blank?
          vals = %w[price original_price price_from price_to].map { |k| p[k] }.compact.map(&:to_f)
          Array(p['variants']).each do |v|
            next unless v.is_a?(Hash)
            vals << v['price'].to_f if v['price']
            vals << v['original_price'].to_f if v['original_price']
          end
          vals = vals.select(&:positive?)
          from = (p['price_from'] || p['price']).to_f
          to = (p['price_to'] || p['price_from'] || p['price']).to_f
          products[id] = {
            prices: vals.uniq,
            from: from,
            range: p['has_variant_prices'] == true || (p['price_to'] && p['price_from'] && (to - from) > TOLERANCE) || false,
            url: p['url']
          }
        end
      elsif data.nil? && raw.is_a?(String)
        # plain-text tool output (FAQ / documentation search): amounts shown with a currency
        global.concat(static_amounts([raw]))
      end
      # other JSON tools (warehouse stock, tracking, link lookup) are NOT a price source
      # (CN-Ops rows can carry cost prices) — nothing is added for them.
    end
    { products: products, global: global.uniq, rejected: rejected }
  end

  def near?(v, list)
    list.any? { |a| (v - a).abs <= TOLERANCE }
  end

  def blocks(text)
    out = []
    pos = 0
    text.split(/(\n[ \t]*\n)/).each do |part|
      out << [pos, pos + part.length] unless part.match?(/\A\n[ \t]*\n\z/)
      pos += part.length
    end
    out
  end

  def mentions(text)
    found = []
    text.to_enum(:scan, WAS_RE).each do
      m = Regexp.last_match
      found << { kind: :was, s: m.begin(0), e: m.end(0), ns: m.begin(:num), v: to_f(m[:num]) }
    end
    text.to_enum(:scan, MAIN_RE).each do
      m = Regexp.last_match
      next if found.any? { |w| w[:kind] == :was && m.begin(:num) >= w[:s] && m.begin(:num) < w[:e] }
      s = m.begin(0)
      e = m.end(0)
      paren = PAREN_WAS_RE.match(text[e..])
      found << { kind: :main, s: s, e: e, ns: m.begin(:num), v: to_f(m[:num]),
                 label_end: m[:label] ? m.end(:label) : s, has_from: !m[:from].nil?,
                 paren_e: paren ? e + paren.end(0) : nil }
    end
    found.sort_by { |x| x[:s] }
  end

  # Returns [new_text, report]
  def apply(text, tool_outputs, static_texts = [])
    text = text.to_s
    ms = mentions(text)
    report = { mentions: ms.size, stripped: [], from_added: [], rejected: [] }
    return [text, report] if ms.empty?

    tools = parse_tools(tool_outputs)
    report[:rejected] = tools[:rejected]
    statics = static_amounts(static_texts)
    all_ids = text.scan(LINK_ID_RE).flatten.uniq
    blks = blocks(text)
    all_tool_prices = tools[:products].values.flat_map { |p| p[:prices] }

    edits = [] # [start, end, replacement]
    safe_lines = {}
    paired_was = []
    ms.each do |m|
      blk = blks.find { |a, b| m[:s] >= a && m[:s] < b } || [0, text.length]
      ids = text[blk[0]...blk[1]].scan(LINK_ID_RE).flatten.uniq
      ids = all_ids if ids.empty? && all_ids.size == 1
      prods = if ids.any?
                ids.filter_map { |i| tools[:products][i] }
              else
                tools[:products].values
              end
      allowed = prods.flat_map { |p| p[:prices] } + statics + tools[:global]
      allowed += all_tool_prices if ids.empty?
      line_no = text[0...m[:s]].count("\n")
      if m[:kind] == :was
        next if paired_was.include?(m[:s])
        next if near?(m[:v], allowed)

        edits << [m[:s], m[:e], '']
        report[:stripped] << m[:v]
        next
      end

      if near?(m[:v], allowed)
        # traceable — enforce «يبدأ من» on the minimum of a product whose variants differ
        ranged = prods.find { |p| p[:range] && (m[:v] - p[:from]).abs <= TOLERANCE }
        before = text[[0, m[:ns] - 25].max...m[:ns]]
        if ranged && !m[:has_from] && !before.match?(FROM_NEAR_RE)
          edits << [m[:ns], m[:ns], FROM_PREFIX]
          report[:from_added] << m[:v]
        end
        next
      end

      e = m[:paren_e] || m[:e]
      if m[:paren_e]
        w = ms.find { |x| x[:kind] == :was && x[:s] >= m[:e] && x[:s] < m[:paren_e] }
        paired_was << w[:s] if w
      end
      repl = safe_lines[line_no] ? '' : SAFE_SENTENCE
      safe_lines[line_no] = true
      edits << [m[:s], e, repl]
      report[:stripped] << m[:v]
    end
    return [text, report] if edits.empty?

    out = text.dup
    edits.sort_by { |s, _e, _r| -s }.each { |s, e, r| out[s...e] = r }
    out = out.gsub(/[ \t]+\n/, "\n").gsub(/[ \t]{2,}/, ' ').gsub(/\(\s*\)/, '')
    if report[:stripped].any? && !out.match?(URL_RE)
      url = all_ids.filter_map { |i| tools[:products].dig(i, :url) }.first ||
            tools[:products].values.filter_map { |p| p[:url] }.first
      out = "#{out.rstrip}\n#{url}" if url.present?
    end
    [out, report]
  end
end

module QaydaoFalseTransfer
  module_function

  AFFIRM_RE = /(سأحوّلك|سأحولك|سوف أحوّلك|سوف أحولك|سأقوم بتحويلك|أن أحوّلك|أن أحولك|راح أحوّلك|راح أحولك|بحوّلك|بحولك|سيتم تحويلك|جاري تحويلك|أحوّلك الآن|أحولك الآن)/

  # true when the text affirms a transfer (not an offer phrased as a question)
  def affirms?(text)
    t = text.to_s
    m = AFFIRM_RE.match(t)
    return false unless m

    sentence_tail = t[m.end(0)..].to_s.split(/[.!\n。]/).first.to_s
    !sentence_tail.include?('؟') && !sentence_tail.include?('?')
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  Rails.application.config.to_prepare do
    # === (3) PRICE GUARD on the finalized V2 result ==========================
    if defined?(Captain::Assistant::AgentRunnerService) &&
       !Captain::Assistant::AgentRunnerService.included_modules.map(&:name).include?('QaydaoPriceGuardRunner')
      pg_mod = Module.new do
        def self.name = 'QaydaoPriceGuardRunner'

        def process_agent_result(result)
          response = super
          qaydao_price_guard!(response, result)
        end

        private

        # Collect every tool result of THIS run (the runner is built per job).
        def add_usage_metadata_callback(runner)
          r = super
          begin
            r.on_tool_complete do |tool_name, tool_result, *_rest|
              (@qaydao_tool_outputs ||= []) << [tool_name.to_s, tool_result]
            end
          rescue StandardError => e
            Rails.logger.warn("[qaydao-price-guard] tool capture not installed: #{e.message}")
          end
          r
        end

        def qaydao_price_guard!(response, result)
          return response unless response.is_a?(Hash)

          text = response['response']
          return response unless text.is_a?(String) && text.present? && text != 'conversation_handoff'

          outputs = Array(@qaydao_tool_outputs).dup
          Array(result.respond_to?(:messages) ? result.messages : nil).each do |msg|
            next unless msg.is_a?(Hash) && msg[:role].to_s == 'tool'

            c = msg[:content]
            c = c.text if c.respond_to?(:text)
            outputs << ['tool_message', c.to_s] unless outputs.any? { |_n, o| o.to_s == c.to_s }
          end
          statics = [@assistant&.config&.dig('instructions'), @assistant&.config&.dig('instruction')]
          begin
            statics += Array(@assistant&.scenarios&.pluck(:instruction))
          rescue StandardError
            nil
          end

          new_text, rep = QaydaoPriceGuard.apply(text, outputs, statics.compact)
          if new_text != text
            Rails.logger.warn("[qaydao-price-guard] conv=##{@conversation&.id} display=#{@conversation&.display_id} " \
                              "stripped=#{rep[:stripped].inspect} from_added=#{rep[:from_added].inspect} " \
                              "rejected=#{rep[:rejected].inspect} tools=#{outputs.map(&:first).inspect} " \
                              "original=#{text[0, 300].inspect}")
            response['response'] = new_text
            response['reasoning'] = [response['reasoning'], "qaydao_price_guard(stripped=#{rep[:stripped].size},from=#{rep[:from_added].size})"].compact.join(' | ')
          elsif rep[:mentions].to_i.positive?
            Rails.logger.info("[qaydao-price-guard] conv=##{@conversation&.id} ok mentions=#{rep[:mentions]} tools=#{outputs.map(&:first).inspect}")
          end
          response
        rescue StandardError => e
          Rails.logger.error("[qaydao-price-guard] FAIL-OPEN conv=##{@conversation&.id}: #{e.class}: #{e.message}")
          response
        end
      end
      Captain::Assistant::AgentRunnerService.prepend(pg_mod)
      Rails.logger.info('[qaydao-patch] price guard applied (AgentRunnerService#process_agent_result)')
    end

    # === (4) ONE REPLY PER CUSTOMER TURN + (5) FALSE-TRANSFER BACKSTOP ======
    if defined?(Captain::Conversation::ResponseBuilderJob) &&
       !Captain::Conversation::ResponseBuilderJob.included_modules.map(&:name).include?('QaydaoTurnDedupe')
      td_mod = Module.new do
        def self.name = 'QaydaoTurnDedupe'

        private

        # Snapshot the newest customer message BEFORE the history is read: anything
        # newer than this id was not seen by the LLM in this job.
        def collect_previous_messages
          begin
            @qaydao_turn_incoming_id = Conversation.uncached do
              @conversation.messages.where(message_type: :incoming).maximum(:id)
            end
          rescue StandardError => e
            @qaydao_turn_incoming_id = nil
            Rails.logger.warn("[qaydao-turn-dedupe] snapshot failed conv ##{@conversation&.id}: #{e.message}")
          end
          super
        end

        def create_messages
          if qaydao_skip_turn_reply?
            # blank the text so outer patches (soft-handoff detection) do not act on an unsent reply
            @response = @response.merge('response' => '') if @response.is_a?(Hash)
            return
          end
          super
          qaydao_false_transfer_backstop
        end

        def qaydao_skip_turn_reply?
          return false if @conversation.nil? || @qaydao_turn_incoming_id.nil?

          conn = ActiveRecord::Base.connection
          conn.execute("SELECT pg_advisory_xact_lock(91827, #{@conversation.id.to_i})") if conn.transaction_open?
          latest = Conversation.uncached { @conversation.messages.where(message_type: :incoming).maximum(:id) }
          if latest && latest > @qaydao_turn_incoming_id
            Rails.logger.info("[qaydao-turn-dedupe] conv ##{@conversation.id} SKIP stale reply: newer customer message ##{latest} " \
                              "arrived after this job read history (saw ##{@qaydao_turn_incoming_id}); its own job will answer")
            return true
          end
          answered = Conversation.uncached do
            @conversation.messages.where(sender_type: 'Captain::Assistant', message_type: :outgoing, private: false)
                         .where('id > ?', @qaydao_turn_incoming_id).exists?
          end
          if answered
            Rails.logger.info("[qaydao-turn-dedupe] conv ##{@conversation.id} SKIP duplicate: Captain already replied after customer message ##{@qaydao_turn_incoming_id}")
            return true
          end
          false
        rescue StandardError => e
          Rails.logger.warn("[qaydao-turn-dedupe] FAIL-OPEN conv ##{@conversation&.id}: #{e.message}")
          false
        end

        def qaydao_false_transfer_backstop
          text = @response.is_a?(Hash) ? @response['response'].to_s : @response.to_s
          return unless QaydaoFalseTransfer.affirms?(text)
          return unless Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) } == 'pending'

          Rails.logger.warn("[qaydao-false-transfer] conv ##{@conversation.id} reply promised a transfer without handoff -> forcing handoff")
          if respond_to?(:qaydao_escalate_assign_and_label!, true)
            qaydao_escalate_assign_and_label!('false-transfer')
          else
            @conversation.bot_handoff!
          end
        rescue StandardError => e
          Rails.logger.warn("[qaydao-false-transfer] failed conv ##{@conversation&.id}: #{e.message}")
        end
      end
      Captain::Conversation::ResponseBuilderJob.prepend(td_mod)
      Rails.logger.info('[qaydao-patch] one-reply-per-turn + false-transfer backstop applied (ResponseBuilderJob)')
    end
  end
end
