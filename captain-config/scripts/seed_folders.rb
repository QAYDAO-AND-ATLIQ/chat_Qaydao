# frozen_string_literal: true
# ============================================================================
# QAYDAO Chatwoot — Canonical Folders (Custom Views) Seeder
# ============================================================================
# WHY THIS EXISTS
#   Chatwoot "Folders" (CustomFilter rows) are PER-USER and private. They are
#   NOT inherited. A new agent — or a restored/rebuilt DB — starts with zero
#   folders, so saved views silently disappear for that user (e.g. Amira had 0).
#
# WHAT THIS DOES
#   Treats the 9 standard folders below as the SINGLE SOURCE OF TRUTH and
#   guarantees EVERY user in the account owns all of them.
#
# GUARANTEES
#   - Idempotent       : safe to run on every boot / every 6h via cron.
#   - Onboarding-safe  : any newly added agent gets all 9 folders automatically.
#   - Non-destructive  : never overwrites a user's own edited query by default.
#   - Self-healing     : re-creates anything deleted/lost.
#
# FORCE RESYNC (only when a definition below changes intentionally):
#   docker exec -e FOLDERS_FORCE_SYNC=1 chatwoot_sidekiq \
#     bundle exec rails runner /tmp/seed_folders.rb
#
# RUN VIA: captain-config/scripts/apply_folders.sh  (host cron, every 6h)
# ============================================================================

ACCOUNT_ID   = (ENV["FOLDERS_ACCOUNT_ID"] || 1).to_i
FORCE_SYNC   = ENV["FOLDERS_FORCE_SYNC"].to_s == "1"
CONVERSATION = 0 # CustomFilter.filter_types[:conversation]

# --- Reusable query builders (mirror Chatwoot's saved-filter payload) -------
def status_eq(values, last: false)
  { "values" => values, "attribute_key" => "status",
    "query_operator" => (last ? nil : "and"),
    "attribute_model" => "standard", "filter_operator" => "equal_to" }
end

def label_eq(values)
  { "values" => values, "attribute_key" => "labels", "query_operator" => nil,
    "attribute_model" => "standard", "filter_operator" => "equal_to" }
end

ACTIVE = %w[open pending].freeze

# --- THE 9 CANONICAL FOLDERS (source of truth) ------------------------------
CANONICAL_FOLDERS = [
  { name: "🔴 تذاكر عاجلة غير معيّنة", filter_type: CONVERSATION,
    query: { "payload" => [
      status_eq(%w[open]),
      { "values" => %w[urgent], "attribute_key" => "priority", "query_operator" => "and",
        "attribute_model" => "standard", "filter_operator" => "equal_to" },
      { "values" => [], "attribute_key" => "assignee_id", "query_operator" => nil,
        "attribute_model" => "standard", "filter_operator" => "is_not_present" },
    ] } },

  { name: "📦 تذاكر الشحن النشطة", filter_type: CONVERSATION,
    query: { "payload" => [status_eq(ACTIVE), label_eq(%w[الشحن])] } },

  { name: "🔄 تذاكر الإرجاع المعلّقة", filter_type: CONVERSATION,
    query: { "payload" => [status_eq(ACTIVE), label_eq(%w[الإرجاع])] } },

  { name: "💼 تذاكر VIP", filter_type: CONVERSATION,
    query: { "payload" => [status_eq(ACTIVE), label_eq(%w[vip])] } },

  { name: "🏢 تذاكر B2B", filter_type: CONVERSATION,
    query: { "payload" => [status_eq(ACTIVE), label_eq(%w[جملة_b2b تأثيث_مشروع شركات])] } },

  { name: "⏰ SLA متجاوزة", filter_type: CONVERSATION,
    query: { "payload" => [
      status_eq(ACTIVE),
      { "values" => [], "attribute_key" => "sla_policy_id", "query_operator" => nil,
        "attribute_model" => "standard", "filter_operator" => "is_present" },
    ] } },

  { name: "📅 تذاكر اليوم الجديدة", filter_type: CONVERSATION,
    query: { "payload" => [
      status_eq(%w[open]),
      { "values" => %w[1], "attribute_key" => "created_at", "query_operator" => nil,
        "attribute_model" => "standard", "filter_operator" => "days_before" },
    ] } },

  { name: "📋 كل النشطة (Open + Pending)", filter_type: CONVERSATION,
    query: { "payload" => [status_eq(ACTIVE, last: true)] } },

  { name: "🤖 محوّلة من QAYDAO AI", filter_type: CONVERSATION,
    query: { "payload" => [status_eq(ACTIVE), label_eq(%w[تتبع_معلق])] } },
].freeze

# --- Helpers ----------------------------------------------------------------
def normalize(query)
  JSON.parse(query.to_json) # stable, order-insensitive comparison form
end

# --- Apply ------------------------------------------------------------------
account = Account.find_by(id: ACCOUNT_ID)
abort("❌ Account #{ACCOUNT_ID} not found") unless account

created = updated = unchanged = 0
users = account.users.order(:id)

puts "📁 QAYDAO Folders seeder — account ##{account.id} (#{account.name})"
puts "   Users: #{users.size} · Folders/user: #{CANONICAL_FOLDERS.size} · FORCE_SYNC=#{FORCE_SYNC}"
puts "-" * 60

users.find_each do |user|
  CANONICAL_FOLDERS.each do |f|
    cf = CustomFilter.find_or_initialize_by(account: account, user: user, name: f[:name])

    if cf.new_record?
      cf.filter_type = f[:filter_type]
      cf.query       = f[:query]
      cf.save!
      created += 1
    elsif FORCE_SYNC && (normalize(cf.query) != normalize(f[:query]) || cf.filter_type != f[:filter_type])
      cf.filter_type = f[:filter_type]
      cf.query       = f[:query]
      cf.save!
      updated += 1
    else
      unchanged += 1
    end
  end
end

puts "-" * 60
puts "✅ Done. created=#{created} updated=#{updated} unchanged=#{unchanged}"
puts "   Total folders now: #{CustomFilter.where(account_id: account.id).count}"

# Integrity check — every user MUST own all canonical folders
missing = []
users.find_each do |user|
  owned = CustomFilter.where(account_id: account.id, user_id: user.id).pluck(:name)
  gap   = CANONICAL_FOLDERS.map { |f| f[:name] } - owned
  missing << "#{user.name} (##{user.id}) → #{gap.join(', ')}" unless gap.empty?
end

if missing.empty?
  puts "🔒 Integrity OK — all #{users.size} users own all #{CANONICAL_FOLDERS.size} folders."
else
  puts "⚠️  Integrity GAP:"
  missing.each { |m| puts "   - #{m}" }
end
