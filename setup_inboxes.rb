account = Account.first

# 1) Live Chat Widget
web_widget = Channel::WebWidget.create!(
  account: account,
  website_url: 'https://qaydao.com',
  welcome_title: 'مرحباً بك في QAYDAO 👋',
  welcome_tagline: 'كيف يمكننا مساعدتك اليوم؟',
  widget_color: '#c9a84c'
)
web_inbox = Inbox.create!(
  account: account,
  name: 'QAYDAO موقع',
  channel: web_widget
)
puts 'Live Chat Inbox created: ' + web_inbox.name
puts 'Widget Token: ' + web_widget.website_token

# 2) Email
email_channel = Channel::Email.create!(
  account: account,
  email: 'support@qaydao.com',
  forward_to_email: 'support@qaydao.com'
)
email_inbox = Inbox.create!(
  account: account,
  name: 'QAYDAO بريد',
  channel: email_channel
)
puts 'Email Inbox created: ' + email_inbox.name

# 3) WhatsApp (placeholder)
whatsapp_channel = Channel::Whatsapp.create!(
  account: account,
  phone_number: '+966500000000',
  provider: 'whatsapp_cloud',
  provider_config: {
    'api_key' => 'PLACEHOLDER',
    'phone_number_id' => 'PLACEHOLDER',
    'business_account_id' => 'PLACEHOLDER'
  }
)
whatsapp_inbox = Inbox.create!(
  account: account,
  name: 'QAYDAO واتساب',
  channel: whatsapp_channel
)
puts 'WhatsApp Inbox created: ' + whatsapp_inbox.name

puts ''
puts '=== Summary ==='
puts 'Total Inboxes: ' + account.inboxes.count.to_s
account.inboxes.each do |inbox|
  puts '  - ' + inbox.name + ' (' + inbox.channel_type + ')'
end
