"""
QAYDAO Quality Guard — section 1: official-policy verification (RULES-based, no AI).
Source of truth = qg_policies table (manually entered official text, or future Salla sync).
Detection is deterministic:
  - the agent reply mentions a policy CATEGORY (shipping/return/cancellation/...) AND
  - either states a NUMBER that conflicts with the official numbers_or_limits,
    OR makes an absolute claim (always/never/free/guaranteed) that the official text qualifies.
Low-confidence / hedging replies never fire (section 1.11). Alerts are Private Notes only.
"""
import re
from classifier import normalize, snippet

# category -> trigger keywords (normalized) that indicate the reply is ABOUT this policy
CATEGORY_TRIGGERS = {
    "shipping_policy":     ["شحن", "توصيل", "يوصل", "الشحنه", "مناطق التوصيل"],
    "delivery_time_policy":["مده الشحن", "مده التوصيل", "خلال يومين", "يوصل اليوم", "يوصل بكره", "وقت التوصيل"],
    "cancellation_policy": ["الغاء", "تلغي", "نلغي", "الغي"],
    "return_policy":       ["استرجاع", "ترجع", "نرجع", "اعاده", "ارجاع"],
    "refund_policy":       ["استرداد", "نرجع لك المبلغ", "رد المبلغ", "المبلغ"],
    "warranty_policy":     ["ضمان", "كفاله"],
    "installation_policy": ["تركيب", "تركيبه"],
    "payment_policy":      ["دفع", "سداد", "تقسيط"],
    "pricing_policy":      ["سعر", "اسعار", "ثمن"],
    "offers_policy":       ["عرض", "عروض", "خصم", "خصومات", "تخفيض"],
}

# absolute / promise markers (normalized) — these are the risky claims to verify
ABSOLUTE_MARKERS = [
    "دائما", "ابدا", "اكيد", "مجاني", "نضمن", "مضمون", "كل المنتجات", "كل المناطق",
    "في اي وقت", "بدون رسوم", "بدون اي رسوم", "نهائيا", "لاي سبب", "فورا",
]

# section 1.11 safe hedging — never fire
SAFE_HEDGES = [
    "ساتحقق", "سوف اتحقق", "حسب الموقع الرسمي", "حسب السياسه", "قد تختلف",
    "لا استطيع التاكيد", "لا اقدر اؤكد", "ساراجع", "قبل مراجعه الطلب", "سنتحقق",
]

_pool = None
def bind_pool(p):
    global _pool
    _pool = p


def _extract_numbers(norm_text):
    return set(re.findall(r"\d+", norm_text))


async def load_active_policies():
    p = await _pool()
    async with p.acquire() as c:
        rows = await c.fetch("SELECT * FROM qg_policies WHERE is_active ORDER BY policy_category")
    return [dict(r) for r in rows]


async def check_policy(body: str):
    """Return alert dict or None. Deterministic; conservative to avoid false positives."""
    t = normalize(body or "")
    if not t:
        return None
    # section 1.11: hedging => safe
    for h in SAFE_HEDGES:
        if normalize(h) in t:
            return None

    policies = await load_active_policies()
    if not policies:
        return None

    # which categories does the reply touch?
    touched = []
    for cat, triggers in CATEGORY_TRIGGERS.items():
        if any(normalize(k) in t for k in triggers):
            touched.append(cat)
    if not touched:
        return None

    has_absolute = any(normalize(m) in t for m in ABSOLUTE_MARKERS)
    reply_numbers = _extract_numbers(t)

    by_cat = {}
    for pol in policies:
        by_cat.setdefault(pol["policy_category"], pol)

    for cat in touched:
        pol = by_cat.get(cat)
        if not pol:
            continue
        official_nums = set(re.findall(r"\d+", pol.get("numbers_or_limits") or ""))

        # (a) number conflict: reply states a number that is NOT in the official set,
        #     while the category has defined official numbers
        if official_nums and reply_numbers:
            conflicting = reply_numbers - official_nums
            # ignore tiny/quantity-like noise: require the conflicting number be "policy-sized"
            policy_sized = {n for n in conflicting if len(n) >= 2}
            if policy_sized:
                return _mk(cat, "high", pol,
                           f"\u0627\u0644\u0631\u062f \u064a\u0630\u0643\u0631 \u0631\u0642\u0645\u0627\u064b ({', '.join(sorted(policy_sized))}) \u064a\u062e\u062a\u0644\u0641 \u0639\u0646 \u0627\u0644\u0645\u0639\u0644\u0648\u0645\u0629 \u0627\u0644\u0631\u0633\u0645\u064a\u0629.",
                           body)

        # (b) absolute claim on a high-risk category that the official text qualifies
        if has_absolute and cat in ("cancellation_policy", "return_policy", "refund_policy", "warranty_policy"):
            return _mk(cat, "high", pol,
                       "\u0627\u0644\u0631\u062f \u064a\u062d\u062a\u0648\u064a \u0648\u0639\u062f\u0627\u064b/\u0625\u0637\u0644\u0627\u0642\u0627\u064b \u0642\u062f \u064a\u062e\u0627\u0644\u0641 \u0627\u0644\u0633\u064a\u0627\u0633\u0629 \u0627\u0644\u0631\u0633\u0645\u064a\u0629.",
                       body)
        if has_absolute and cat in ("shipping_policy", "delivery_time_policy", "installation_policy", "offers_policy"):
            return _mk(cat, "medium", pol,
                       "\u0627\u0644\u0631\u062f \u064a\u062d\u062a\u0648\u064a \u0625\u0637\u0644\u0627\u0642\u0627\u064b \u0642\u062f \u064a\u062e\u0627\u0644\u0641 \u0627\u0644\u0645\u0639\u0644\u0648\u0645\u0629 \u0627\u0644\u0631\u0633\u0645\u064a\u0629.",
                       body)
    return None


def _mk(category, severity, pol, reason, body):
    return {
        "alert_type": "official_policy_mismatch",
        "severity": severity,
        "matched_rule": category,
        "ai_reason": reason,
        "suggested_correction": (
            "\u064a\u0631\u062c\u0649 \u062a\u0639\u062f\u064a\u0644 \u0627\u0644\u0631\u062f \u0644\u064a\u0637\u0627\u0628\u0642 \u0627\u0644\u0645\u0639\u0644\u0648\u0645\u0629 \u0627\u0644\u0631\u0633\u0645\u064a\u0629: "
            + (pol.get("official_statement") or "")[:180]),
        "policy_reference": (pol.get("source_url") or f"Section 1 / {category}"),
        "official_policy_snippet": (pol.get("official_statement") or "")[:200],
        "source_url": pol.get("source_url"),
    }
