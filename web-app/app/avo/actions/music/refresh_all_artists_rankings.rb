class Avo::Actions::Music::RefreshAllArtistsRankings < Avo::BaseAction
  self.name = "Refresh All Artists Rankings"
  self.message = "This will recalculate rankings for all artists based on their albums and songs. This process runs in the background and may take several minutes."
  self.confirm_button_label = "Refresh All Rankings"
  self.standalone = true
  self.visible = -> { view.index? }

  def handle(query:, fields:, current_user:, resource:, **args)
    config = Music::Artists::RankingConfiguration.default_primary

    unless config
      return error "No default artist ranking configuration found. Please create one first."
    end

    Music::CalculateAllArtistsRankingsJob.perform_async(config.id)

    succeed "All artists ranking calculation queued. This will process in the background."
  end
end
