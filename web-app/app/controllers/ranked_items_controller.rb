class RankedItemsController < ApplicationController
  def self.expected_ranking_configuration_type
    nil
  end

  private

  def find_ranking_configuration
    if params[:ranking_configuration_id].present?
      @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    else
      expected_type = self.class.expected_ranking_configuration_type
      @ranking_configuration = if expected_type
        RankingConfiguration.where(type: expected_type).global.primary.first
      else
        RankingConfiguration.global.primary.first
      end
    end

    raise ActiveRecord::RecordNotFound unless @ranking_configuration
  end

  def validate_ranking_configuration_type
    expected_type = self.class.expected_ranking_configuration_type
    return unless expected_type

    unless @ranking_configuration.type == expected_type
      raise ActiveRecord::RecordNotFound
    end
  end
end
