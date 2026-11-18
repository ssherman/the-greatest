# frozen_string_literal: true

# One transient alert, appended to #toast-region by a Turbo Stream. The message
# is plain text and goes through normal ERB escaping, so callers may pass titles.
class Toast::MessageComponent < ViewComponent::Base
  # action: {label:, url:, method:, params:} renders a button_to beside the message.
  def initialize(message:, type: :success, action: nil, ttl: 4000)
    @message = message
    @type = type
    @action = action
    @ttl = ttl
  end

  private

  attr_reader :message, :type, :action, :ttl
end
