# Creates the "تتبع_معلق" label + automation rule that turns Captain's
# order-not-found escalations into tickets assigned to the support team.
# Idempotent. Run via: docker cp + rails runner, or from apply flow.
account = Account.find(1)
label = account.labels.find_or_create_by(title: "تتبع_معلق") do |l|
  l.description = "طلبات تتبع لم تُوجد في النظام — تحتاج مراجعة موظف"
  l.color = "#FF6B6B"; l.show_on_sidebar = true
end
puts "label: #{label.title} (#{label.id})"
ESCALATION_PHRASE = "تم رفع طلبك لخدمة العملاء للمراجعة"
rule = account.automation_rules.find_or_initialize_by(name: "تصعيد تتبع الطلبات غير الموجودة")
rule.description = "عند رفع طلب تتبع غير موجود، أضف label وأسنده لفريق الدعم"
rule.event_name = "message_created"; rule.active = true
rule.conditions = [{ "values" => [ESCALATION_PHRASE], "attribute_key" => "content",
                     "query_operator" => nil, "filter_operator" => "contains" }]
rule.actions = [{ "action_name" => "add_label", "action_params" => ["تتبع_معلق"] },
                { "action_name" => "assign_team", "action_params" => [2] }]
rule.save!
puts "rule: #{rule.id} (active: #{rule.active})"
