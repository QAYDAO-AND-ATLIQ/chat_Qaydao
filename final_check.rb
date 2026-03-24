account = Account.first

puts '=== QAYDAO Chatwoot - Final Report ==='
puts ''
puts '--- Account ---'
puts 'Name: ' + account.name
puts 'Locale: ' + account.locale.to_s
puts 'ID: ' + account.id.to_s
puts ''
puts '--- Inboxes (' + account.inboxes.count.to_s + ') ---'
account.inboxes.each do |inbox|
  puts '  ' + inbox.name + ' (' + inbox.channel_type + ')'
  if inbox.channel_type == 'Channel::WebWidget'
    puts '    Widget Token: ' + inbox.channel.website_token
    puts '    Widget Color: ' + inbox.channel.widget_color.to_s
  end
end
puts ''
puts '--- Users (' + account.users.count.to_s + ') ---'
AccountUser.where(account: account).each do |au|
  puts '  ' + au.user.name + ' <' + au.user.email + '> - Role: ' + au.role.to_s
end
puts ''
puts '--- Super Admins ---'
SuperAdmin.all.each do |sa|
  puts '  ' + sa.name.to_s + ' <' + sa.email + '>'
end
puts ''
puts '--- Automation Rules (' + account.automation_rules.count.to_s + ') ---'
account.automation_rules.each do |rule|
  puts '  ' + rule.name + ' (Active: ' + rule.active.to_s + ')'
end
puts ''
puts '--- Installation Config ---'
['INSTALLATION_NAME', 'BRAND_NAME', 'WIDGET_BRAND_URL'].each do |key|
  config = InstallationConfig.find_by(name: key)
  if config
    puts '  ' + key + ': ' + config.value.to_s
  end
end
puts ''
puts '=== END REPORT ==='
