# QAYDAO FAQ Review patch
# Adds team-review tracking to Captain FAQ responses:
#   - PATCH .../captain/assistant_responses/:id  with {assistant_response:{reviewed:true|false}}
#     stamps reviewed_at + reviewed_by_id (Current.user)
#   - index: ?reviewed=true|false filter + @reviewed_count / @responses_total_for_review for meta
# Safe: fails open to stock behavior if columns are missing (e.g. fresh DB after upgrade).
# Mounted via docker-compose bind mount. 2026-06-10.

module QaydaoFaqReviewPatch
  def self.columns_ready?
    @columns_ready = Captain::AssistantResponse.column_names.include?('reviewed') if @columns_ready.nil?
    @columns_ready
  rescue StandardError
    false
  end

  module ControllerPatch
    def update
      ar = params[:assistant_response]
      if QaydaoFaqReviewPatch.columns_ready? && ar.respond_to?(:key?) && ar.key?(:reviewed)
        val = ActiveModel::Type::Boolean.new.cast(ar[:reviewed])
        @response.reviewed = val
        @response.reviewed_at = val ? Time.current : nil
        @response.reviewed_by_id = val ? Current.user&.id : nil
        @response.save!
        extra = response_params
        @response.update!(extra) if extra.present?
      else
        super
      end
    end

    private

    def permitted_params
      params.permit(:id, :assistant_id, :page, :document_id, :account_id, :status, :search, :reviewed)
    end

    def apply_filters(base_query)
      scoped = super
      return scoped unless QaydaoFaqReviewPatch.columns_ready?

      begin
        @responses_total_for_review = scoped.count
        @reviewed_count = scoped.where(reviewed: true).count
      rescue StandardError => e
        Rails.logger.warn("[QAYDAO-FAQ-REVIEW] meta count failed: #{e.message}")
      end

      if permitted_params[:reviewed].present?
        val = ActiveModel::Type::Boolean.new.cast(permitted_params[:reviewed])
        scoped = scoped.where(reviewed: val)
      end
      scoped
    end
  end
end

Rails.application.config.to_prepare do
  controller = 'Api::V1::Accounts::Captain::AssistantResponsesController'.safe_constantize
  if controller && !controller.ancestors.include?(QaydaoFaqReviewPatch::ControllerPatch)
    controller.prepend(QaydaoFaqReviewPatch::ControllerPatch)
    Rails.logger.info('[QAYDAO PATCH] FAQ review patch applied (reviewed flag + filter + meta counts)')
  end
end
