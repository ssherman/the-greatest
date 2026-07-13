# frozen_string_literal: true

class Admin::AddListToConfigurationModalComponent < ViewComponent::Base
  def initialize(ranking_configuration:)
    @ranking_configuration = ranking_configuration
  end

  def available_lists
    list_type = Admin::DomainRouting.ranking_configuration_config(@ranking_configuration)&.dig(:list_type)

    return List.none if list_type.nil?

    already_added_list_ids = @ranking_configuration.ranked_lists.pluck(:list_id)

    List
      .where(type: list_type)
      .where(status: [:active, :approved])
      .where.not(id: already_added_list_ids)
      .order(created_at: :desc)
  end
end
