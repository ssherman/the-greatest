class RankedItemsController < ApplicationController
  def self.ranking_configuration_class
    RankingConfiguration
  end

  private

  def find_ranking_configuration
    @ranking_configuration = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      self.class.ranking_configuration_class.default_primary
    end

    raise ActiveRecord::RecordNotFound unless @ranking_configuration
  end

  def validate_ranking_configuration_type
    expected_class = self.class.ranking_configuration_class
    return if expected_class == RankingConfiguration

    unless @ranking_configuration.is_a?(expected_class)
      raise ActiveRecord::RecordNotFound
    end
  end
end
