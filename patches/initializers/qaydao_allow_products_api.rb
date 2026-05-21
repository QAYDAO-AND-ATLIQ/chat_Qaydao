# QAYDAO Patch: Allow Captain Custom Tools to call our own /products/* API
# Date: 2026-05-20
# Approach: Module prepend pattern (cleanest Ruby way to override methods)

module QaydaoEndpointValidatableOverride
  QAYDAO_ALLOWED_PATHS = ['/products/api/'].freeze

  private

  def validate_endpoint_host(uri)
    if uri.host.blank?
      errors.add(:endpoint_url, 'must have a valid hostname')
      return
    end

    if uri.host == Concerns::SafeEndpointValidatable::FRONTEND_HOST
      # QAYDAO: Allow specific safe paths on our own host
      if QAYDAO_ALLOWED_PATHS.any? { |path| uri.path.to_s.start_with?(path) }
        Rails.logger.info("[QAYDAO] Allowed same-host Custom Tool URL: #{uri.to_s.split('?').first}")
        return
      end
      errors.add(:endpoint_url, 'cannot point to the application itself')
      return
    end

    Concerns::SafeEndpointValidatable::DISALLOWED_HOSTS.each do |pattern|
      matched = if pattern.is_a?(Regexp)
                  uri.host =~ pattern
                else
                  uri.host.downcase == pattern
                end
      next unless matched
      errors.add(:endpoint_url, 'cannot use disallowed hostname')
      break
    end
  end
end

Rails.application.config.to_prepare do
  Concerns::SafeEndpointValidatable.prepend(QaydaoEndpointValidatableOverride)
  Rails.logger.info('[QAYDAO] SafeEndpointValidatable patched to allow /products/api/')
end
