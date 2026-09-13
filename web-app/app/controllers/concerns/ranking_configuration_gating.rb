# frozen_string_literal: true

# Who may see a ranking configuration resolved from /rc/:id, and which of
# those views is a "custom ranking" the layout should flag.
#
# Global configurations (the primary and the year rollups) are visible to
# everyone and never touch the session, so the edge-cached pages stay
# session-free. A user-owned configuration is visible when its owner shared
# it or when the viewer is the owner; anything else is a 404, never a 403 --
# a redirect would confirm the id exists.
#
# Included by ApplicationController; every finder that reads
# params[:ranking_configuration_id] calls gate_ranking_configuration! on the
# record it found (load_ranking_configuration, RankedItemsController,
# Games::RankedItemsController, Books::FiltersController).
module RankingConfigurationGating
  extend ActiveSupport::Concern

  private

  def gate_ranking_configuration!(config)
    return if config.nil? || config.global?

    unless config.user_shared? || config.user_id == current_user&.id
      raise ActiveRecord::RecordNotFound
    end

    @custom_ranking_configuration = config
  end
end
