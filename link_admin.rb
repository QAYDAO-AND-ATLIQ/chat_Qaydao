account = Account.first
user = User.find_by(email: 'admin@qaydao.com')

if user.nil?
  user = User.new(
    name: 'QAYDAO Admin',
    email: 'admin@qaydao.com',
    password: 'QaydaoAdmin@2025',
    password_confirmation: 'QaydaoAdmin@2025',
    type: 'User'
  )
  user.skip_confirmation!
  user.save!
  puts 'User created: ' + user.email
else
  puts 'User already exists: ' + user.email
  user.confirm unless user.confirmed?
end

existing = AccountUser.find_by(account: account, user: user)
if existing.nil?
  account_user = AccountUser.create!(
    account: account,
    user: user,
    role: :administrator
  )
  puts 'AccountUser linked with role: ' + account_user.role.to_s
else
  puts 'AccountUser already linked with role: ' + existing.role.to_s
end

puts 'Account name: ' + account.name
puts 'Account locale: ' + account.locale.to_s
