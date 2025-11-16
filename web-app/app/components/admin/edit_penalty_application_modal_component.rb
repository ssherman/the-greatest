# frozen_string_literal: true

class Admin::EditPenaltyApplicationModalComponent < ViewComponent::Base
  def initialize(penalty_application:)
    @penalty_application = penalty_application
  end
end
