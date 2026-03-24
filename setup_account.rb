account = Account.create!(
  name: 'QAYDAO | كواي داو',
  locale: 'ar'
)
puts 'Account created: ' + account.name + ' (ID: ' + account.id.to_s + ')'

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

account_user = AccountUser.create!(
  account: account,
  user: user,
  role: :administrator
)
puts 'AccountUser created with role: ' + account_user.role.to_s
