"""
QAYDAO Agent Quality Guard — classifier v2 (RULES ONLY).
Batch A+B: expanded banned-phrase dictionaries (spec sections 2-4),
greeting / closing / rating-close detection (sections 6-8),
with Arabic normalization (section 9). Customer messages are never classified.
Official-policy semantic mismatch (section 1) is NOT here — it needs the AI classifier
(deferred) and the policy content source (Salla API), per approval.
"""
import re
import unicodedata

# ---------- PII masking (applied BEFORE storing any snippet) ----------
_PII_PATTERNS = [
    (re.compile(r'\bSA\d{22}\b', re.I), '[IBAN]'),
    (re.compile(r'\b\d{10}\b'), '[ID/ACCT]'),
    (re.compile(r'\b\d{16}\b'), '[CARD]'),
    (re.compile(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'), '[CARD]'),
]

def mask_pii(text: str) -> str:
    if not text:
        return ""
    out = text
    for pat, repl in _PII_PATTERNS:
        out = pat.sub(repl, out)
    return out

def snippet(text: str, limit: int = 200) -> str:
    return mask_pii(text or "")[:limit]

# ---------- Arabic normalization (spec section 9) ----------
_TATWEEL = '\u0640'
_DIAC = re.compile(r'[\u064b-\u0652\u0670\u0653-\u0655]')   # harakat + dagger alef etc.
_PUNCT = re.compile(r'[^\w\s\u0600-\u06ff]')

def normalize(s: str) -> str:
    if not s:
        return ""
    s = s.replace(_TATWEEL, '')
    s = _DIAC.sub('', s)
    # unify alef forms, alef maqsura, teh marbuta, hamza variants
    s = (s.replace('\u0623', '\u0627')   # أ -> ا
           .replace('\u0625', '\u0627')   # إ -> ا
           .replace('\u0622', '\u0627')   # آ -> ا
           .replace('\u0649', '\u064a')   # ى -> ي
           .replace('\u0629', '\u0647')   # ة -> ه
           .replace('\u0624', '\u0648')   # ؤ -> و
           .replace('\u0626', '\u064a'))  # ئ -> ي
    s = _PUNCT.sub(' ', s)
    s = re.sub(r'\s+', ' ', s).strip().lower()
    return s

def _norm_list(phrases):
    return [normalize(p) for p in phrases]

# ---------- Banned-phrase dictionaries (normalized at import) ----------
# section 2.1 + 2.2 + 2.3 : accusations / blame / belittling toward customer (external)
ABUSE_HIGH = _norm_list([
    # 2.1 calling customer a liar
    "انت كذاب","انتي كذابه","انت كذابه","لا تكذب","لا تكذبين","كلامك كذب","هذا كذب",
    "انت غير صادق","كلامك غير صادق","واضح انك تكذب","العميل كذاب","العميله كذابه","كلامك غير صحيح",
    # 2.3 direct insults
    "ما تفهم","انت ما تفهم","انتي ما تفهمين","واضح انك ما تفهم","استيعابك غلط",
    "لا تتفلسف","لا تزعجنا","لا تضيع وقتنا","احترم نفسك","تكلم باحترام",
    "هذا مو شغلنا","مو شغلنا","ما لنا علاقه","دبر نفسك","تصرف بنفسك",
])
ABUSE_MEDIUM = _norm_list([
    # 2.2 blaming the customer
    "انت غلطان","انتي غلطانه","الغلط منك","المشكله منك","الخطا منك","السبب منك","انت السبب",
    "انت ما وضحت","انت ما فهمت","فهمك غلط","واضح انك ما فهمت","انت اخترت غلط","هذا خطاك",
    "هذا بسبب اهمالك","لو كنت قرات كان عرفت","راجع كلامك","اقرا الكلام زين",
    # 2.3 dry style
    "لا تجادل","لا تناقش","لا تكرر الكلام","كلامك كثير","طلبك غير منطقي","كلامك غير منطقي","اسلوبك غلط",
])
# section 2.4 : dodging responsibility (external)
EVASION = _norm_list([
    "مو مسؤوليتنا","ما لنا دخل","راجع شركه الشحن","المشكله من الشحن","المشكله من المورد",
    "المشكله من المصنع","ما نقدر نسوي لك شي","هذا الموجود","تحمل الوضع","انتظر وخلاص",
    "ما بيدنا شي","هذا نظام الشركه وخلاص","سياسه وخلاص","ما نقدر نساعدك",
])
# section 2.5 : unconfirmed promises (external) -> policy_risk
PROMISE = _norm_list([
    "اكيد يوصل بكره","اكيد يوصل اليوم","نضمن لك يوصل اليوم","نضمن لك يوصل بكره",
    "اكيد بنرجع المبلغ","اكيد بنبدل المنتج","اكيد بنعوضك","ابشر بنحلها فورا","خلاص اعتبرها محلوله",
    "راح نلغي الطلب اكيد","راح نخصم لك اكيد","راح نعطيك تعويض","المنتج متوفر اكيد","الشحنه طالعه اكيد",
    "تم الحل بدون تحقق","تم الالغاء بدون تحقق","تم الاسترجاع بدون تحقق",
])
# section 3.1 : pricing/offers attitude -> sales_risk
SALES_RISK = _norm_list([
    "السعر واضح قدامك","ليش ما طلبت وقت العرض","انتهى العرض وخلاص","ما نقدر نغير السعر عشانك",
    "الاسعار مو على كيفك","اذا ما عجبك السعر لا تطلب","دور الارخص","هذا سعرنا واذا ما عجبك عادي",
    "انت تقارن غلط","السعر ارتفع وانتهى الموضوع",
])
# section 3.2 : cancellation/return refusal -> policy_risk
POLICY_RISK = _norm_list([
    "ما تقدر تلغي","ما يحق لك ترجع","طلبك مرفوض","انتهت المهله وخلاص","انت تاخرت","هذا شرط واضح",
    "كان لازم تقرا السياسه","ما بنرجع لك شي","الاسترجاع غير ممكن وخلاص","ما عندك حق","النظام ما يسمح وانتهى",
])
# section 3.3 : shipping-delay handling -> delay_handling_risk
DELAY_HANDLING = _norm_list([
    "انتظر وخلاص","الشحن ياخذ وقت","هذا طبيعي","ما نقدر نسوي شي","المشكله من شركه الشحن",
    "كل العملاء ينتظرون","تاخرت الشحنه وخلاص","ما عندي تحديث","لا تسال كل يوم",
    "اذا وصلتك بنبلغك","واضح في الموقع مده الشحن",
])
# section 4.1 : unprofessional labeling of customer INSIDE notes
NOTE_CLIENT_LABEL = _norm_list([
    "هذا العميل مزعج","العميل مزعج","هذا العميل قروشه","العميل قروشه","هذا العميل نشبه","العميل نشبه",
    "العميل ما يفهم","العميله ما تفهم","العميل يتعب","العميل متعب","عميل متعب","عميله متعبه",
    "يضيع وقتنا","مضيع وقتنا","عميل سيء","عميله سيئه","عميل قليل ادب","العميل قليل ادب",
    "العميل وقح","هذا العميل وقح","العميل كذاب","العميل يتفلسف","العميل يزعجنا","العميل غير محترم",
    "لا احد يرد عليه","لا تردون عليه","طنشوه","تجاهلوه","خلوه ينتظر","لا تعطونه وجه",
])
# section 4.2 : agent-to-agent arguing in notes
NOTE_ARGUMENT = _norm_list([
    "ليش ما رديت","لماذا لم ترد","انت السبب","شغلك غلط","شغلك سيء","المفروض تفهم","لا تدخل في المحادثه",
    "انا قلت لك","غلطتك","هذا خطاك","ليش حولتها لي","لا تحولها لي","مو شغلي","انا مالي دخل",
    "حلها انت","لا ترميها علي","انت تاخرت","انت ما تابعت","انت لخبطت العميل",
])

# section 1.11 : safe/professional phrases that must NOT fire (policy-check guard)
SAFE_OVERRIDES = _norm_list([
    "ساتحقق","سوف اتحقق","حسب الموقع الرسمي","قد تختلف الرسوم حسب الحاله",
    "لا استطيع التاكيد قبل مراجعه الطلب","ساراجع الصفحه الرسميه واعود لك",
    "ساتحقق من السياسه","ساتحقق من الحاله",
])
# section 12 : documentation-quote guard for notes ("العميل قال: ...")
QUOTE_MARKERS = _norm_list(["العميل قال", "العميله قالت", "قال العميل", "قالت العميله"])

# ---------- greeting / closing / rating (sections 6,7,8) ----------
# 2026-07-11 FIX (Omar): "وعليكم السلام" — the standard Arabic RESPONSE to a customer's
# salaam — was missing. Substring matching meant it never matched "السلام عليكم", so every
# agent who politely returned the greeting was flagged missing_greeting (conv 4616/166/1440/24).
# The system was literally penalising politeness. Expanded to cover response + common variants.
GREET_HELLO = _norm_list([
    # responses to a customer-initiated salaam (were entirely absent)
    "وعليكم السلام","و عليكم السلام","عليكم السلام","وعليكم",
    # initiations
    "السلام عليكم","اهلا","اهلين","أهلا وسهلا","اهلا وسهلا","مرحبا","مرحبتين",
    "حياك الله","حياك","حياكم الله","اسعد الله","صباح الخير","مساء الخير",
    "هلا","هلا وغلا","يا هلا","يهلا",
])
GREET_SELF  = _norm_list(["معك","انا","اسمي","معاك"])
GREET_BRAND = _norm_list(["كواي داو","خدمه عملاء","خدمة عملاء","فريق كواي","قيداو","qaydao"])

CLOSING_OK = _norm_list([
    "اي سؤال","استفسار اخر","شي اخر","مساعده اضافيه","تحتاج اي مساعده",
    "هل تم حل","اقدر اساعدك بشي","اقدر اخدمك",
])
RATING_OK = _norm_list([
    "اتركك مع التقييم","مع التقييم","شكرا لتواصلك","سعدنا بخدمتك","يسعدنا خدمتك",
])
# weak final messages that should have had a closing/rating (section 7/8 negatives)
WEAK_FINAL = _norm_list(["تم","خلاص","انتهى","اغلقت الطلب","تمت الافاده","مع السلامه"])


def _hit(norm_text, phrases):
    for p in phrases:
        if p and p in norm_text:
            return p
    return None


def classify(*, body: str, is_private: bool, message_type: str):
    """Phase-1/Batch-A+B rules. Returns dict or None. Text-only."""
    raw = (body or "").strip()
    if not raw:
        return None
    t = normalize(raw)

    if is_private:
        # documentation-quote guard: "العميل قال: ..." is not a violation by itself
        quoted = _hit(t, QUOTE_MARKERS)
        m = _hit(t, NOTE_CLIENT_LABEL)
        if m and not quoted:
            return _mk("unprofessional_note", "high", m,
                       "\u0648\u0635\u0641 \u063a\u064a\u0631 \u0645\u0647\u0646\u064a \u0644\u0644\u0639\u0645\u064a\u0644 \u062f\u0627\u062e\u0644 \u0627\u0644\u0646\u0648\u062a \u0627\u0644\u062f\u0627\u062e\u0644\u064a.",
                       "\u0648\u062b\u0651\u0642 \u0627\u0644\u062d\u0627\u0644\u0629 \u0628\u0645\u0648\u0636\u0648\u0639\u064a\u0629: \u00ab\u0627\u0644\u0639\u0645\u064a\u0644 \u0645\u0633\u062a\u0627\u0621 \u0648\u064a\u062d\u062a\u0627\u062c \u0645\u062a\u0627\u0628\u0639\u0629\u00bb \u0623\u0648 \u00ab\u0627\u0644\u062d\u0627\u0644\u0629 \u062a\u062d\u062a\u0627\u062c \u062a\u0635\u0639\u064a\u062f\u00bb.",
                       "Section 4.1")
        m = _hit(t, NOTE_ARGUMENT)
        if m:
            return _mk("internal_argument", "medium", m,
                       "\u062c\u062f\u0627\u0644/\u0644\u0648\u0645 \u0628\u064a\u0646 \u0627\u0644\u0645\u0648\u0638\u0641\u064a\u0646 \u062f\u0627\u062e\u0644 \u0627\u0644\u0646\u0648\u062a \u0627\u0644\u062f\u0627\u062e\u0644\u064a.",
                       "\u0627\u0644\u0646\u0648\u062a \u0644\u062a\u0648\u062b\u064a\u0642 \u0627\u0644\u062d\u0627\u0644\u0629 \u0644\u0627 \u0644\u0644\u0646\u0642\u0627\u0634. \u062d\u0648\u0651\u0644 \u0627\u0644\u062e\u0644\u0627\u0641 \u0627\u0644\u062a\u0634\u063a\u064a\u0644\u064a \u0644\u0644\u0645\u0634\u0631\u0641 \u062e\u0627\u0631\u062c \u0645\u062d\u0627\u062f\u062b\u0629 \u0627\u0644\u0639\u0645\u064a\u0644.",
                       "Section 4.2")
        return None

    # ----- external reply to customer -----
    # safe-override guard (section 1.11): professional hedging never fires
    if _hit(t, SAFE_OVERRIDES):
        return None

    m = _hit(t, ABUSE_HIGH)
    if m:
        return _mk("abuse", "high", m,
                   "\u0644\u0641\u0638 \u0645\u0633\u064a\u0621/\u0627\u062a\u0647\u0627\u0645 \u0644\u0644\u0639\u0645\u064a\u0644 \u0641\u064a \u0631\u062f \u062e\u0627\u0631\u062c\u064a.",
                   "\u0623\u0639\u062f \u0627\u0644\u0635\u064a\u0627\u063a\u0629 \u0628\u0627\u062d\u062a\u0631\u0627\u0645: \u00ab\u0646\u062d\u062a\u0627\u062c \u0646\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u062a\u0641\u0627\u0635\u064a\u0644 \u0642\u0628\u0644 \u062a\u0623\u0643\u064a\u062f \u0627\u0644\u0645\u0639\u0644\u0648\u0645\u0629\u00bb.",
                   "Section 2.1/2.3")
    m = _hit(t, ABUSE_MEDIUM)
    if m:
        return _mk("unprofessional_reply", "medium", m,
                   "\u0623\u0633\u0644\u0648\u0628 \u062c\u0627\u0641/\u062a\u062d\u0645\u064a\u0644 \u0627\u0644\u0639\u0645\u064a\u0644 \u0627\u0644\u062e\u0637\u0623.",
                   "\u00ab\u0642\u062f \u064a\u0643\u0648\u0646 \u062d\u0635\u0644 \u0633\u0648\u0621 \u0641\u0647\u0645\u060c \u062e\u0644\u0646\u0627 \u0646\u0631\u0627\u062c\u0639 \u0627\u0644\u062a\u0641\u0627\u0635\u064a\u0644 \u0645\u0639\u0627\u064b\u00bb.",
                   "Section 2.2")
    m = _hit(t, EVASION)
    if m:
        return _mk("unprofessional_reply", "medium", m,
                   "\u062a\u0647\u0631\u0651\u0628 \u0645\u0646 \u0627\u0644\u0645\u0633\u0624\u0648\u0644\u064a\u0629 \u0623\u0645\u0627\u0645 \u0627\u0644\u0639\u0645\u064a\u0644.",
                   "\u00ab\u0633\u0646\u0631\u0627\u062c\u0639 \u0627\u0644\u062d\u0627\u0644\u0629 \u0645\u0639 \u0627\u0644\u0642\u0633\u0645 \u0627\u0644\u0645\u062e\u062a\u0635 \u0648\u0646\u062d\u062f\u062b\u0643 \u0628\u0627\u0644\u0646\u062a\u064a\u062c\u0629\u00bb.",
                   "Section 2.4")
    m = _hit(t, PROMISE)
    if m:
        return _mk("policy_risk", "high", m,
                   "\u0648\u0639\u062f \u063a\u064a\u0631 \u0645\u0624\u0643\u062f \u0642\u0628\u0644 \u0627\u0644\u062a\u062d\u0642\u0642.",
                   "\u00ab\u0633\u0623\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u062d\u0627\u0644\u0629 \u0648\u0623\u0639\u0648\u062f \u0644\u0643 \u0628\u062a\u062d\u062f\u064a\u062b \u0645\u0624\u0643\u062f\u00bb.",
                   "Section 2.5")
    m = _hit(t, POLICY_RISK)
    if m:
        return _mk("policy_risk", "high", m,
                   "\u0646\u0641\u064a \u0633\u064a\u0627\u0633\u0629/\u0631\u0641\u0636 \u0625\u0644\u063a\u0627\u0621 \u0623\u0648 \u0627\u0633\u062a\u0631\u062c\u0627\u0639 \u0628\u0623\u0633\u0644\u0648\u0628 \u062d\u0627\u062f.",
                   "\u00ab\u0633\u0623\u0631\u0627\u062c\u0639 \u0637\u0644\u0628\u0643 \u062d\u0633\u0628 \u0633\u064a\u0627\u0633\u0629 \u0627\u0644\u0625\u0644\u063a\u0627\u0621 \u0648\u0627\u0644\u0627\u0633\u062a\u0631\u062c\u0627\u0639 \u0648\u0623\u0648\u0636\u062d \u0644\u0643 \u0627\u0644\u062e\u064a\u0627\u0631\u0627\u062a\u00bb.",
                   "Section 3.2")
    m = _hit(t, SALES_RISK)
    if m:
        return _mk("sales_risk", "medium", m,
                   "\u0623\u0633\u0644\u0648\u0628 \u063a\u064a\u0631 \u0645\u0647\u0646\u064a \u062d\u0648\u0644 \u0627\u0644\u0633\u0639\u0631/\u0627\u0644\u0639\u0631\u0648\u0636.",
                   "\u00ab\u0627\u0644\u0623\u0633\u0639\u0627\u0631 \u0642\u062f \u062a\u062a\u063a\u064a\u0631 \u062d\u0633\u0628 \u0627\u0644\u0639\u0631\u0648\u0636\u060c \u0648\u064a\u0633\u0639\u062f\u0646\u064a \u0623\u0631\u0627\u062c\u0639 \u0644\u0643 \u0623\u0641\u0636\u0644 \u062e\u064a\u0627\u0631 \u0645\u062a\u0627\u062d\u00bb.",
                   "Section 3.1")
    m = _hit(t, DELAY_HANDLING)
    if m:
        return _mk("delay_handling_risk", "medium", m,
                   "\u062a\u0639\u0627\u0645\u0644 \u063a\u064a\u0631 \u0645\u0647\u0646\u064a \u0645\u0639 \u062a\u0623\u062e\u0631 \u0627\u0644\u0634\u062d\u0646.",
                   "\u00ab\u0646\u0639\u062a\u0630\u0631 \u0639\u0646 \u0627\u0644\u062a\u0623\u062e\u064a\u0631\u060c \u0648\u0633\u0623\u062a\u062d\u0642\u0642 \u0645\u0646 \u0622\u062e\u0631 \u062a\u062d\u062f\u064a\u062b \u0644\u0644\u0634\u062d\u0646\u0629 \u0627\u0644\u0622\u0646\u00bb.",
                   "Section 3.3")
    return None


# Approved WhatsApp opening templates (outreach openers sent BEFORE customer engages).
# These are pre-approved business-initiated messages, not a customer-service reply,
# so they must NOT trigger missing_greeting. Matched by distinctive normalized phrases.
OPENING_TEMPLATE_MARKERS = _norm_list([
    "هل الوقت مناسب الان",
    "نود التواصل معك هل الوقت مناسب",
    "تحيه طيبه من فريق كواي داو نود التواصل",
    "عميلنا العزيز تحيه طيبه من فريق كواي داو",
])

def is_opening_template(body: str) -> bool:
    t = normalize(body or "")
    if not t:
        return False
    return any(m and m in t for m in OPENING_TEMPLATE_MARKERS)


# 2026-07-11 FIX (Omar): Chatwoot already flags template messages, but the classifier
# never looked. It only matched a hardcoded list of 4 Arabic phrases, so ANY new
# Facebook/WhatsApp template produced a false missing_greeting (conv 4656/4794/4387/
# 4312/4550/4635). Read the authoritative flag from the message row instead.
#   - additional_attributes['template_params'] / ['is_template']  -> template send
#   - content_type 'template' / 'incoming_email'                  -> not a CS reply
def is_template_message(msg: dict | None) -> bool:
    """Authoritative template check using Chatwoot's own message metadata."""
    if not msg:
        return False
    ct = str(msg.get("content_type") or "").strip().lower()
    if ct in ("template", "incoming_email"):
        return True
    # Chatwoot enum: 0=text .. 9=template (numeric form from raw SQL/webhook)
    if str(msg.get("content_type")) == "9":
        return True
    aa = msg.get("additional_attributes") or {}
    if isinstance(aa, dict):
        # presence-based, not truthiness-based: Chatwoot may send an empty
        # template_params ({}) for a template with no variables — that is still a template.
        for key in ("template_params", "is_template", "template"):
            if key in aa and aa.get(key) is not False:
                return True
    return False


def classify_first_reply(body: str, msg: dict | None = None):
    """section 6: first human reply must greet, and identify (name or brand).

    2026-07-11 FIX (Omar): previously required greeting AND self AND brand — all three.
    That forced one rigid sentence and flagged correct, polite replies. A reply that
    greets and identifies (either by agent name or by brand) is professionally valid.
    Returns dict or None.
    """
    # authoritative: a template send is not a customer-service reply at all
    if is_template_message(msg):
        return None
    t = normalize(body or "")
    if not t:
        return None
    # approved outreach opening template -> not a missing greeting
    if is_opening_template(body):
        return None
    has_hello = bool(_hit(t, GREET_HELLO))
    has_self  = bool(_hit(t, GREET_SELF))
    has_brand = bool(_hit(t, GREET_BRAND))
    # greeting is required; identification may be by name OR brand (not both)
    if has_hello and (has_self or has_brand):
        return None
    return _mk("missing_greeting", "low", "first_reply",
               "\u0627\u0644\u0631\u062f \u0627\u0644\u0623\u0648\u0644 \u0644\u0627 \u064a\u062d\u062a\u0648\u064a \u0639\u0644\u0649 \u062a\u0631\u062d\u064a\u0628 \u0645\u0639 \u062a\u0639\u0631\u064a\u0641 \u0628\u0627\u0644\u0627\u0633\u0645 \u0623\u0648 \u0630\u0643\u0631 \u0643\u0648\u0627\u064a \u062f\u0627\u0648.",
               "\u00ab\u0623\u0647\u0644\u0627\u064b \u0628\u0643\u060c \u0645\u0639\u0643 [\u0627\u0644\u0627\u0633\u0645] \u0645\u0646 \u062e\u062f\u0645\u0629 \u0639\u0645\u0644\u0627\u0621 \u0643\u0648\u0627\u064a \u062f\u0627\u0648\u060c \u0643\u064a\u0641 \u0623\u0642\u062f\u0631 \u0623\u0633\u0627\u0639\u062f\u0643\u061f\u00bb \u2014 \u0648\u064a\u064f\u0642\u0628\u0644 \u0623\u064a\u0636\u0627\u064b \u0627\u0644\u0631\u062f \u0639\u0644\u0649 \u0627\u0644\u0633\u0644\u0627\u0645: \u00ab\u0648\u0639\u0644\u064a\u0643\u0645 \u0627\u0644\u0633\u0644\u0627\u0645\u060c \u0645\u0639\u0643 [\u0627\u0644\u0627\u0633\u0645]...\u00bb",
               "Section 6")


# ===== Customer abuse / threats toward the company (incoming customer messages) =====
# Insults / accusations from the customer
CUSTOMER_ABUSE = _norm_list([
    "نصابين","نصاب","محتالين","محتال","حراميه","حرامي","لصوص","سراق","سرقتوني","نصبتو علي","نصب",
    "كذابين","كذاب","كذابه","تكذبون","دجالين","دجال","مزورين","تزوير",
    "زباله","قذرين","قذر","حقيرين","حقير","اوساخ","وسخين","كلاب","حمير","اغبياء","غبي","غبيه",
    "تافهين","تافه","فاشلين","فاشل","نذاله","اولاد","قليلين ادب","قليل ادب","عديمين","بلا اخلاق",
    "خونه","خاين","مخادعين","مخادع","لا تستحون","ما تستحون","عار عليكم","يا حقراء",
])
# Threats (legal / defamation / harm)
CUSTOMER_THREAT = _norm_list([
    "بشهر فيكم","راح اشهر","بفضحكم","راح افضحكم","بفضحكم بالسوشال","بنشر تجربتي","بنشركم",
    "برفع عليكم","راح ارفع عليكم","بشتكي عليكم","راح اشتكي","بلغ عنكم","رايح للمحكمه","بوديكم المحكمه",
    "بوديكم المحاكم","قضيه","دعوى","محامي","بحرككم","بكلم محامي","هيئه حمايه المستهلك","بلغ التجاره",
    "بدمر سمعتكم","بخرب سمعتكم","راح اجيكم","بجيكم للمكتب","تنتظرون مني","ما راح اسكت","بعلمكم",
    "تهديد","بكسر","براجعكم بطريقتي","تعرفون مين انا",
])

def classify_customer_abuse(body: str):
    """Detect abuse/insults or threats coming FROM the customer. Returns alert dict or None.
    This produces an INTERNAL note to support the agent (calm, official reply, escalate)."""
    t = normalize(body or "")
    if not t:
        return None
    is_threat = bool(_hit(t, CUSTOMER_THREAT))
    is_abuse = bool(_hit(t, CUSTOMER_ABUSE))
    if not (is_threat or is_abuse):
        return None
    # threats are higher severity
    severity = "high" if is_threat else "medium"
    reason = ("\u0627\u0644\u0639\u0645\u064a\u0644 \u0648\u062c\u0651\u0647 \u062a\u0647\u062f\u064a\u062f\u0627\u064b (\u062a\u0634\u0647\u064a\u0631/\u0634\u0643\u0648\u0649/\u0642\u0627\u0646\u0648\u0646\u064a)." if is_threat
              else "\u0627\u0644\u0639\u0645\u064a\u0644 \u0627\u0633\u062a\u062e\u062f\u0645 \u0623\u0644\u0641\u0627\u0638\u0627\u064b \u0645\u0633\u064a\u0626\u0629 \u062a\u062c\u0627\u0647 \u0627\u0644\u0634\u0631\u0643\u0629.")
    # ready-made official reply + reminder for the agent
    suggestion = ("\u0631\u062f \u0631\u0633\u0645\u064a \u0645\u0642\u062a\u0631\u062d: \u00ab\u0646\u0639\u062a\u0630\u0631 \u0639\u0645\u0651\u0627 \u0628\u062f\u0631 \u0645\u0646 \u0627\u0646\u0632\u0639\u0627\u062c\u060c \u0648\u0646\u0624\u0643\u062f \u062d\u0631\u0635\u0646\u0627 \u0639\u0644\u0649 \u062e\u062f\u0645\u062a\u0643. \u0633\u0646\u0631\u0627\u062c\u0639 \u0637\u0644\u0628\u0643 \u0628\u0639\u0646\u0627\u064a\u0629 \u0648\u0646\u0639\u0648\u062f \u0644\u0643 \u0628\u0627\u0644\u062d\u0644 \u0627\u0644\u0645\u0646\u0627\u0633\u0628 \u0641\u064a \u0623\u0633\u0631\u0639 \u0648\u0642\u062a.\u00bb | "
                  "\u062a\u0630\u0643\u064a\u0631: \u0644\u0627 \u062a\u062c\u0627\u062f\u0644 \u0627\u0644\u0639\u0645\u064a\u0644\u060c \u0627\u0644\u062a\u0632\u0645 \u0627\u0644\u0647\u062f\u0648\u0621 \u0648\u0627\u0644\u0627\u062d\u062a\u0631\u0627\u0641\u060c \u0648\u0627\u0631\u0641\u0639 \u0627\u0644\u062d\u0627\u0644\u0629 \u0644\u0644\u0645\u0634\u0631\u0641 \u0639\u0646\u062f \u0627\u0644\u062d\u0627\u062c\u0629.")
    return {
        "alert_type": "customer_abuse",
        "severity": severity,
        "matched_rule": "customer_threat" if is_threat else "customer_abuse",
        "ai_reason": reason,
        "suggested_correction": suggestion,
        "policy_reference": "Customer Conduct / \u0633\u0644\u0648\u0643 \u0627\u0644\u0639\u0645\u064a\u0644",
    }


def classify_closing(body: str):
    """sections 7+8: final message before close should have closing-check and rating."""
    t = normalize(body or "")
    if not t:
        return None
    has_closing = bool(_hit(t, CLOSING_OK))
    has_rating  = bool(_hit(t, RATING_OK))
    is_weak     = bool(_hit(t, WEAK_FINAL))
    if has_closing and has_rating:
        return None
    if not has_closing and (is_weak or not has_rating):
        if not has_rating and not has_closing:
            return _mk("missing_rating_close", "low", "closing",
                       "\u0644\u0645 \u064a\u062a\u0645 \u0627\u0633\u062a\u062e\u062f\u0627\u0645 \u0631\u0633\u0627\u0644\u0629 \u0625\u063a\u0644\u0627\u0642 \u0645\u0647\u0646\u064a\u0629 \u0623\u0648 \u062a\u0631\u0643 \u0627\u0644\u0639\u0645\u064a\u0644 \u0645\u0639 \u0627\u0644\u062a\u0642\u064a\u064a\u0645.",
                       "\u00ab\u0634\u0643\u0631\u0627\u064b \u0644\u062a\u0648\u0627\u0635\u0644\u0643 \u0645\u0639 \u0643\u0648\u0627\u064a \u062f\u0627\u0648\u060c \u064a\u0633\u0639\u062f\u0646\u0627 \u062e\u062f\u0645\u062a\u0643 \u062f\u0627\u0626\u0645\u0627\u064b\u060c \u0648\u0623\u062a\u0631\u0643\u0643 \u0645\u0639 \u0627\u0644\u062a\u0642\u064a\u064a\u0645\u00bb.",
                       "Section 8")
        return _mk("missing_closing_check", "low", "closing",
                   "\u0644\u0645 \u064a\u062a\u0645 \u0633\u0624\u0627\u0644 \u0627\u0644\u0639\u0645\u064a\u0644 \u0625\u0646 \u0643\u0627\u0646 \u0644\u062f\u064a\u0647 \u0627\u0633\u062a\u0641\u0633\u0627\u0631 \u0623\u062e\u0631 \u0642\u0628\u0644 \u0627\u0644\u0625\u0646\u0647\u0627\u0621.",
                   "\u00ab\u0647\u0644 \u0644\u062f\u064a\u0643 \u0623\u064a \u0633\u0624\u0627\u0644 \u0623\u0648 \u0627\u0633\u062a\u0641\u0633\u0627\u0631 \u0622\u062e\u0631 \u0623\u0642\u062f\u0631 \u0623\u0633\u0627\u0639\u062f\u0643 \u0641\u064a\u0647\u061f\u00bb",
                   "Section 7")
    return None


def _mk(alert_type, severity, matched, reason, suggestion, policy):
    return {
        "alert_type": alert_type, "severity": severity, "matched_rule": matched,
        "ai_reason": reason, "suggested_correction": suggestion, "policy_reference": policy,
    }
