# frozen_string_literal: true

class Admin::AddListToConfigurationModalComponent < ViewComponent::Base
  def initialize(ranking_configuration:)
    @ranking_configuration = ranking_configuration
  end

  def available_lists
    list_type = case @ranking_configuration.type
    when "Books::RankingConfiguration"
      "Books::List"
    when "Movies::RankingConfiguration"
      "Movies::List"
    when "Games::RankingConfiguration"
      "Games::List"
    when "Music::Albums::RankingConfiguration"
      "Music::Albums::List"
    when "Music::Songs::RankingConfiguration"
      "Music::Songs::List"
    end

    return List.none if list_type.nil?

    already_added_list_ids = @ranking_configuration.ranked_lists.pluck(:list_id)

    List
      .where(type: list_type)
      .where(status: [:active, :approved])
      .where.not(id: already_added_list_ids)
      .order(created_at: :desc)
  end
end
