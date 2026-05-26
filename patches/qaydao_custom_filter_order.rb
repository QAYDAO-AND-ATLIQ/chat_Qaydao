# QAYDAO — pin the "محوّلة من QAYDAO AI" custom view to the TOP of the folders
# list for every agent, so AI-handed-off tickets are the first/most visible
# folder (strict follow-up). Chatwoot's controller returns custom_filters with
# no explicit order (so they come out by id = creation order, newest last);
# this prepend re-orders the relation to put our handoff view first, then the
# rest by id. Pure ordering — touches no data. Loaded as a bind-mounted
# initializer on web (and sidekiq, harmless there); survives restarts.

Rails.application.config.to_prepare do
  ctrl = 'Api::V1::Accounts::CustomFiltersController'
  next unless Object.const_defined?(ctrl)
  klass = ctrl.constantize

  unless klass.included_modules.map(&:name).include?('QaydaoFilterOrder')
    klass.prepend(Module.new do
      def self.name = 'QaydaoFilterOrder'

      def fetch_custom_filters
        super
        @custom_filters = @custom_filters.reorder(
          Arel.sql("CASE WHEN name LIKE '%محوّلة من QAYDAO AI%' THEN 0 ELSE 1 END ASC, id ASC")
        )
      rescue StandardError => e
        Rails.logger.warn("[qaydao-filter-order] failed: #{e.message}")
        # نفشل بأمان: نترك الترتيب الأصلي
      end
    end)
    Rails.logger.info('[qaydao-filter-order] pinned handoff view to top of folders')
  end
end
