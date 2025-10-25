class Avo::Actions::Music::RefreshArtistRanking < Avo::BaseAction
  self.name = "Refresh Artist Ranking"
  self.message = "This will recalculate this artist's ranking based on their albums and songs."
  self.confirm_button_label = "Refresh Ranking"
  self.standalone = true
  self.visible = -> { view.show? }

  def handle(query:, fields:, current_user:, resource:, **args)
    artist = query.first

    if query.count > 1
      return error "This action can only be performed on a single artist."
    end

    Music::CalculateArtistRankingJob.perform_async(artist.id)

    succeed "Artist ranking calculation queued for #{artist.name}. Rankings will be updated in the background."
  end
end
