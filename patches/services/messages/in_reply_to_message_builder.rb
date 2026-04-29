class Messages::InReplyToMessageBuilder
  pattr_initialize [:message!, :in_reply_to!, :in_reply_to_external_id!]

  delegate :conversation, to: :message

  def perform
    set_in_reply_to_attribute if @in_reply_to.present? || @in_reply_to_external_id.present?
  end

  private

  def set_in_reply_to_attribute
    found = in_reply_to_message

    if found
      @message.content_attributes[:in_reply_to_external_id] = found.source_id
      @message.content_attributes[:in_reply_to] = found.id
    elsif @in_reply_to_external_id.present?
      # PATCH (qaydao): Original message not in Chatwoot — sent outside (Whatomate/Meta API).
      # Create a placeholder ghost message so the agent SEES that the customer is quoting
      # a previous outbound. Without this, the quote context is silently lost.
      ghost = build_ghost_message
      @message.content_attributes[:in_reply_to_external_id] = ghost.source_id
      @message.content_attributes[:in_reply_to] = ghost.id
    end
  end

  def in_reply_to_message
    return conversation.messages.find_by(id: @in_reply_to) if @in_reply_to.present?
    return conversation.messages.find_by(source_id: @in_reply_to_external_id) if @in_reply_to_external_id

    nil
  end

  def build_ghost_message
    # Use the customer reply's timestamp minus 1s so the placeholder appears just before
    base_time = @message.created_at || Time.current
    conversation.messages.create!(
      content: '📤 [رسالة سابقة — أُرسلت من نظام التسويق التلقائي]',
      message_type: :outgoing,
      inbox_id: conversation.inbox_id,
      account_id: conversation.account_id,
      sender: nil,
      source_id: @in_reply_to_external_id,
      content_attributes: { external_origin: 'whatomate', ghost: true },
      created_at: base_time - 1.second,
      updated_at: base_time - 1.second
    )
  rescue ActiveRecord::RecordNotUnique
    # Race: another reply created the ghost first — fetch and use it
    conversation.messages.find_by(source_id: @in_reply_to_external_id)
  end
end
