account = Account.first

# Set QAYDAO brand colors via installation config
configs = {
  'INSTALLATION_NAME' => 'QAYDAO Support',
  'BRAND_NAME' => 'QAYDAO | كواي داو',
  'WIDGET_BRAND_URL' => 'https://qaydao.com',
  'TERMS_URL' => 'https://qaydao.com/terms',
  'PRIVACY_URL' => 'https://qaydao.com/privacy'
}

configs.each do |key, value|
  config = InstallationConfig.find_or_create_by(name: key)
  config.update!(value: value)
  puts "Set #{key} = #{value}"
end

# Update account settings
account.update!(
  name: 'QAYDAO | كواي داو',
  locale: 'ar'
)

puts 'Brand settings applied successfully!'
puts 'Account: ' + account.name
puts 'Locale: ' + account.locale
