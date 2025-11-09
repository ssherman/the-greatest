module Actions
  module Admin
    module Music
      class RefreshArtistRanking < Actions::Admin::BaseAction
        def self.name
          "Refresh Artist Ranking"
        end

        def self.message
          "This will recalculate this artist's ranking based on their albums and songs."
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single artist.") if models.count > 1

          artist = models.first
          ::Music::CalculateArtistRankingJob.perform_async(artist.id)

          succeed "Artist ranking calculation queued for #{artist.name}."
        end
      end
    end
  end
end
