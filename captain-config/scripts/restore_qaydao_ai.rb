#!/usr/bin/env ruby
# QAYDAO AI — restore the assistant's full brain (instruction + 4 scenarios)
# from the JSON snapshot. Use after a DB loss/rebuild so all quality rules
# (tone, no-markdown/emoji, whole prices, match-accuracy, numbered formatting,
# mandatory product link, guiding close) come back exactly.
#
# Run:
#   docker cp captain-config/snapshots/qaydao_ai_snapshot.json chatwoot_sidekiq:/tmp/
#   docker cp captain-config/scripts/restore_qaydao_ai.rb chatwoot_sidekiq:/tmp/
#   docker exec chatwoot_sidekiq bundle exec rails runner /tmp/restore_qaydao_ai.rb
require 'json'

path = '/tmp/qaydao_ai_snapshot.json'
abort("✗ snapshot غير موجود: #{path}") unless File.exist?(path)
snap = JSON.parse(File.read(path))

assistant = Captain::Assistant.find(snap['assistant_id'])

# 1) restore base instruction (+ keep existing feature flags)
cfg = assistant.config.dup
cfg['instruction'] = snap['instruction']
(snap['config_flags'] || {}).each { |k, v| cfg[k] = v }
assistant.update!(config: cfg)
puts "✓ التعليمات الأساسية (#{snap['instruction'].to_s.length} حرف)"

# 2) restore each scenario by id
restored = 0
snap['scenarios'].each do |sc|
  s = Captain::Scenario.find_by(id: sc['id'], assistant_id: assistant.id)
  if s
    s.update!(title: sc['title'], description: sc['description'],
              instruction: sc['instruction'], enabled: sc['enabled'])
    restored += 1
    puts "✓ سيناريو #{sc['id']}: #{sc['title']}"
  else
    puts "⚠ سيناريو #{sc['id']} غير موجود (تخطّي)"
  end
end
puts "=DONE=: استُعيدت التعليمات + #{restored} سيناريو من snapshot #{snap['exported_at']}"
