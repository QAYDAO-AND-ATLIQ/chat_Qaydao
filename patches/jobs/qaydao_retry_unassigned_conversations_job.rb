# QAYDAO 2026-05-05: Retry assignment for unassigned conversations every 5 minutes.
#
# Why this exists:
#   Chatwoot's auto-assignment runs only when conversation status changes to 'open'
#   (or resolved/snoozed). If no team agent is online at that moment, the conversation
#   stays unassigned forever — even after agents come back online.
#
# What this job does (every 5 minutes):
#   1. For each target inbox, call existing AutoAssignment::AssignmentJob — this
#      uses the team-based round-robin (شيماء + مروة via team 2).
#   2. If primary team is FULLY offline (none online), fallback to assigning any
#      remaining unassigned conversations to Fai (manager) — but ONLY if she's online.
#   3. If Fai is also offline, conversations remain unassigned (visible in "غير معيّن").
#
# Idempotent: if everyone is already assigned, the job exits cheaply.
# Safe on errors: per-inbox try/rescue isolates failures.
class QaydaoRetryUnassignedConversationsJob < ApplicationJob
  TARGET_INBOX_IDS  = [2, 3, 5, 6].freeze     # Email, WebWidget, WhatsApp, Instagram
  PRIMARY_TEAM_ID   = 2                       # الدعم الفني (شيماء + مروة)
  FALLBACK_EMAILS   = %w[fay@qaydao.com].freeze  # ordered by priority

  queue_as :scheduled_jobs

  def perform
    TARGET_INBOX_IDS.each do |inbox_id|
      begin
        inbox = Inbox.find_by(id: inbox_id)
        next unless inbox&.enable_auto_assignment?

        process_inbox(inbox)
      rescue StandardError => e
        Rails.logger.error "[QAYDAO Retry] inbox=#{inbox_id} failed: #{e.class} #{e.message}"
      end
    end
  end

  private

  def process_inbox(inbox)
    # Step 1: regular team-based assignment (uses existing service, respects team_id)
    AutoAssignment::AssignmentJob.perform_now(inbox_id: inbox.id)

    # Step 2: fallback to Fai if primary team is fully offline
    fallback_if_team_offline(inbox)
  end

  def fallback_if_team_offline(inbox)
    online_ids = fetch_online_user_ids(inbox.account_id)

    # If any primary team member is online, do nothing — they should handle it.
    # (Even if rate-limited, we don't want to bypass them.)
    team_member_ids = Team.find(PRIMARY_TEAM_ID).members.ids
    return if (team_member_ids & online_ids).any?

    fallback_user = find_online_fallback(online_ids)
    return unless fallback_user

    assigned = 0
    inbox.conversations.where(status: 'open', assignee_id: nil).find_each do |conv|
      conv.update!(assignee: fallback_user)
      assigned += 1
    end

    Rails.logger.info(
      "[QAYDAO Fallback] inbox=#{inbox.id} assigned=#{assigned} to=#{fallback_user.email} " \
      "(primary team fully offline)"
    ) if assigned.positive?
  end

  def find_online_fallback(online_ids)
    # Preserve priority order from FALLBACK_EMAILS
    FALLBACK_EMAILS.each do |email|
      user = User.find_by(email: email)
      return user if user && online_ids.include?(user.id)
    end
    nil
  end

  def fetch_online_user_ids(account_id)
    OnlineStatusTracker.get_available_users(account_id)
                       .select { |_, value| value == 'online' }
                       .keys.map(&:to_i)
  end
end
