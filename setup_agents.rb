account = Account.first

# Create agent user
agent = User.new(
  name: 'فريق QAYDAO',
  email: 'support-agent@qaydao.com',
  password: 'Agent@QAYDAO2025',
  password_confirmation: 'Agent@QAYDAO2025',
  type: 'User'
)
agent.skip_confirmation!
agent.save!

# Link as agent to the account
AccountUser.create!(
  account: account,
  user: agent,
  role: :agent
)

puts 'Agent created: ' + agent.name
puts 'Email: ' + agent.email

# Add agent to all inboxes
account.inboxes.each do |inbox|
  InboxMember.create!(
    inbox: inbox,
    user: agent
  )
  puts 'Added to inbox: ' + inbox.name
end

# Also add admin to all inboxes
admin = User.find_by(email: 'admin@qaydao.com')
if admin
  account.inboxes.each do |inbox|
    InboxMember.find_or_create_by!(
      inbox: inbox,
      user: admin
    )
  end
  puts 'Admin added to all inboxes too'
end

puts ''
puts 'Total users in account: ' + account.users.count.to_s

# ---------------------------------------------------------------------------
# NOTE (2026-05-31): Folders/Custom Views are PER-USER and are NOT created here.
# Any new agent is auto-provisioned with all 9 standard folders by:
#   captain-config/scripts/seed_folders.rb  (via apply_folders.sh, host cron /6h)
# To provision immediately after adding an agent, run:
#   /root/chat-qaydao/captain-config/scripts/apply_folders.sh
# ---------------------------------------------------------------------------
