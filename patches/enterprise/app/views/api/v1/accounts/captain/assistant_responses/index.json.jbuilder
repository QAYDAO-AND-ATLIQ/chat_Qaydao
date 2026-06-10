json.payload do
  json.array! @responses do |response|
    json.partial! 'api/v1/models/captain/assistant_response', formats: [:json], resource: response
  end
end

json.meta do
  json.total_count @responses_count
  json.page @current_page
  # --- QAYDAO FAQ review progress (set by qaydao_faq_review.rb patch) ---
  json.reviewed_count @reviewed_count if defined?(@reviewed_count) && !@reviewed_count.nil?
  json.review_total @responses_total_for_review if defined?(@responses_total_for_review) && !@responses_total_for_review.nil?
end
