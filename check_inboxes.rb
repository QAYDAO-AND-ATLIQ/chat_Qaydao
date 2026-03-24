account = Account.first
puts 'Total Inboxes: ' + account.inboxes.count.to_s
account.inboxes.each do |inbox|
  puts '  - ' + inbox.name + ' (' + inbox.channel_type + ')'
  if inbox.channel_type == 'Channel::WebWidget'
    puts '    Widget Token: ' + inbox.channel.website_token
  end
end
