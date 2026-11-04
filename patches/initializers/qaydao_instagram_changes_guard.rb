# QAYDAO 2026-11-04 — Instagram webhook "changes" guard (approved by Rami, staging first).
#
# ROOT CAUSE: Webhooks::InstagramEventsJob treats ANY entry that has a `changes`
# array as a Meta *test* event (test_event? = entry[:changes].present?) and hands
# changes.first.value to Instagram::TestEventService, which reads
# value[:sender][:id]. Real `comments` webhooks (the IG account is subscribed to
# the comments field) have {from, media, id, text} and no `sender`
#   => NoMethodError "undefined method '[]' for nil" -> retries -> dead set
# (prod: 248 dead jobs + 4 lock timeouts, all field=comments, 82 in the last 7 days).
# No DM was lost: none of the dead payloads had `messaging`/`standby`.
# Comments are not supported by Chatwoot's Instagram channel anyway.
#
# FIX: only a `changes` entry with field "messages" and a sender is a test event;
# a batch with nothing processable (no messaging/standby/test event) is skipped
# with one log line BEFORE taking the per-sender Redis lock (the lock key had no
# sender for comments, so all comment jobs contended on one key).
#
# Bind-mount on web + sidekiq + sidekiq_captain.

module QaydaoInstagramChangesGuard
  def perform(entries)
    list = Array(entries).map { |e| qaydao_ig_hash(e) }
    if list.any? && list.none? { |e| qaydao_ig_processable?(e) }
      fields = list.flat_map { |e| Array(e[:changes]).map { |c| qaydao_ig_hash(c)[:field] } }.compact.uniq
      ids = list.flat_map { |e| Array(e[:changes]).map { |c| qaydao_ig_hash(qaydao_ig_hash(c)[:value])[:id] } }.compact
      Rails.logger.info("[qaydao-ig] skipped unsupported Instagram webhook: ig_account=#{list.first[:id]} fields=#{fields.join(',')} item_ids=#{ids.first(5).join(',')}")
      return
    end
    super
  end

  private

  def test_event?(entry)
    Array(entry[:changes]).any? do |c|
      ch = qaydao_ig_hash(c)
      ch[:field].to_s == 'messages' && qaydao_ig_hash(qaydao_ig_hash(ch[:value])[:sender])[:id].present?
    end
  end

  def qaydao_ig_processable?(entry)
    entry[:messaging].present? || entry[:standby].present? || test_event?(entry)
  end

  def qaydao_ig_hash(obj)
    obj.respond_to?(:with_indifferent_access) ? obj.with_indifferent_access : {}.with_indifferent_access
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  Rails.application.config.to_prepare do
    begin
      job = 'Webhooks::InstagramEventsJob'.safe_constantize
      job.prepend(QaydaoInstagramChangesGuard) if job && !(job < QaydaoInstagramChangesGuard)
      Rails.logger.info("[qaydao-patch] Instagram changes guard applied (#{job.present?})")
    rescue StandardError => e
      Rails.logger.error("[qaydao-patch] Instagram changes guard NOT applied: #{e.class} #{e.message}")
    end
  end
end
