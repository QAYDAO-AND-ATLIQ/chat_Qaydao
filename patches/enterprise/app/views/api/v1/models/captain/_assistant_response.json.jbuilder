json.account_id resource.account_id
json.answer resource.answer
json.assistant do
  json.partial! 'api/v1/models/captain/assistant', formats: [:json], resource: resource.assistant
end
json.created_at resource.created_at.to_i

if resource.documentable
  json.documentable do
    json.type resource.documentable_type

    case resource.documentable_type
    when 'Captain::Document'
      json.id resource.documentable.id
      json.external_link resource.documentable.external_link
      json.name resource.documentable.name
    when 'Conversation'
      json.id resource.documentable.display_id
      json.display_id resource.documentable.display_id
    when 'User'
      json.id resource.documentable.id
      json.email resource.documentable.email
      json.available_name resource.documentable.available_name
    end
  end
end

json.id resource.id
json.question resource.question
json.updated_at resource.updated_at.to_i
json.status resource.status
json.edited resource.edited

# --- QAYDAO FAQ review (guarded: safe if columns absent) ---
if resource.respond_to?(:reviewed)
  json.reviewed resource.reviewed ? true : false
  json.reviewed_at resource.reviewed_at&.to_i
  if resource.reviewed_by_id
    qaydao_reviewer = User.find_by(id: resource.reviewed_by_id)
    json.reviewed_by qaydao_reviewer&.available_name
  end
end
