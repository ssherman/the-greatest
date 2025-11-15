# frozen_string_literal: true

class Admin::AttachPenaltyModalComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  def available_penalties
    media_type = @list.type.split("::").first

    Penalty
      .static
      .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
      .where.not(id: @list.penalties.pluck(:id))
      .order(:name)
  end
end
