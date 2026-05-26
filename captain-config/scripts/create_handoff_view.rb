# إنشاء Custom View "محوّلة من QAYDAO AI" لكل موظفي خدمة العملاء + المشرفين
# يجمع تذاكر تتبع_معلق المفتوحة/المعلقة في قائمة واحدة للمراجعة بعد الإجازة
account = Account.find(1)

view_name = "🤖 محوّلة من QAYDAO AI"
query = {
  "payload" => [
    { "values" => ["open", "pending"], "attribute_key" => "status",
      "query_operator" => "and", "attribute_model" => "standard", "filter_operator" => "equal_to" },
    { "values" => ["تتبع_معلق"], "attribute_key" => "labels",
      "query_operator" => nil, "attribute_model" => "standard", "filter_operator" => "equal_to" }
  ]
}

# موظفو خدمة العملاء + المشرفون (نفس من لديهم views حالياً)
target_user_ids = AccountUser.where(account_id: account.id).pluck(:user_id) - [11]
created = 0; skipped = 0

target_user_ids.each do |uid|
  user = User.find_by(id: uid)
  next unless user && account.users.exists?(user.id)
  existing = CustomFilter.find_by(account_id: account.id, user_id: uid, name: view_name, filter_type: 0)
  if existing
    existing.update!(query: query)
    skipped += 1
  else
    CustomFilter.create!(account_id: account.id, user_id: uid, name: view_name,
                         filter_type: 0, query: query)
    created += 1
  end
end

puts "=DONE=: أُنشئ #{created} view جديد، حُدّث #{skipped} موجود"
# تأكيد العدد الذي سيظهر في الـ view
cnt = Conversation.joins(:taggings => :tag)
                  .where(account_id: account.id, status: [0, 2])
                  .where(tags: { name: "تتبع_معلق" }).distinct.count
puts "=COUNT=: #{cnt} تذكرة ستظهر في الـ view الآن"
