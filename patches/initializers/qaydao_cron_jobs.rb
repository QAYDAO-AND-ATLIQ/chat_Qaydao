# QAYDAO 2026-05-05: Register custom QAYDAO cron jobs.
#
# Why this exists (instead of editing config/schedule.yml):
#   Patching schedule.yml requires manual merging on every Chatwoot upgrade.
#   This initializer adds our jobs independently — survives upgrades cleanly.
#
# Registered jobs:
#   - qaydao_retry_unassigned_conversations: every 5 minutes
#     Picks up unassigned conversations and assigns them to شيماء/مروة (team 2)
#     or Fai as fallback. See app/jobs/qaydao_retry_unassigned_conversations_job.rb

Rails.application.config.after_initialize do
  next unless Sidekiq.server?
  next unless defined?(Sidekiq::Cron::Job)

  qaydao_jobs = [
    {
      name:  'qaydao_retry_unassigned_conversations',
      cron:  '*/5 * * * *',
      class: 'QaydaoRetryUnassignedConversationsJob',
      queue: 'scheduled_jobs',
      source: 'qaydao'  # tag so we can manage these separately from Chatwoot core jobs
    }
  ]

  qaydao_jobs.each do |job_config|
    Sidekiq::Cron::Job.create(job_config)
  end

  Rails.logger.info "[QAYDAO Cron] Registered #{qaydao_jobs.size} custom cron job(s)"
end
