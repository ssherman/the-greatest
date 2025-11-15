# frozen_string_literal: true

class Admin::AttachPenaltyModalComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end
end
