# frozen_string_literal: true

class Admin::AddPenaltyToConfigurationModalComponent < ViewComponent::Base
  def initialize(ranking_configuration:)
    @ranking_configuration = ranking_configuration
  end

  def available_penalties
    media_type = @ranking_configuration.type.split("::").first

    Penalty
      .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
      .where.not(id: @ranking_configuration.penalties.pluck(:id))
      .order(:name)
  end
end
