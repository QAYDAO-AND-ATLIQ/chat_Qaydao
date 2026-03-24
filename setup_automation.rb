account = Account.first

automation = account.automation_rules.create!(
  name: 'رد تلقائي - خارج أوقات العمل',
  description: 'يرد تلقائياً على العملاء خارج أوقات الدوام',
  event_name: 'conversation_created',
  conditions: [
    {
      'attribute_key' => 'status',
      'filter_operator' => 'equal_to',
      'values' => ['open'],
      'query_operator' => nil
    }
  ],
  actions: [
    {
      'action_name' => 'send_message',
      'action_params' => [
        "شكراً لتواصلك مع QAYDAO! 🌟\n\nتم استلام رسالتك وسيرد عليك فريقنا خلال أوقات العمل:\nالأحد - الخميس: 9 صباحاً - 6 مساءً\n\nللاستفسارات العاجلة: info@qaydao.com"
      ]
    }
  ],
  active: true
)

puts 'Automation created: ' + automation.name
puts 'Active: ' + automation.active.to_s
puts 'Total automation rules: ' + account.automation_rules.count.to_s
