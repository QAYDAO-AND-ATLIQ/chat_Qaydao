# frozen_string_literal: true
# QAYDAO override — relax login/ip throttle for shared/dynamic office egress IP.
# Office agents share a DYNAMIC public IP in 151.255.0.0/16 (ISP). Chatwoot default
# login/ip = 5 / 5min locks out the whole team collectively. This raises it.
# Per-account protection (login/email 10/15min) + global req/ip (3000/min) stay intact.
# zz_ prefix => loaded AFTER config/initializers/rack_attack.rb, so it overrides it.

return unless defined?(Rack::Attack)

QAYDAO_LOGIN_IP_LIMIT = ENV.fetch('QAYDAO_LOGIN_IP_LIMIT', '60').to_i

Rack::Attack.throttle('login/ip', limit: QAYDAO_LOGIN_IP_LIMIT, period: 5.minutes) do |req|
  if req.path_without_extentions == '/auth/sign_in' && req.post? && req.params['mfa_token'].blank?
    req.ip
  end
end

Rails.logger.info("[qaydao-patch] login/ip throttle overridden -> #{QAYDAO_LOGIN_IP_LIMIT}/5min")
