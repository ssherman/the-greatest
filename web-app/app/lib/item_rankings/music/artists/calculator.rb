module ItemRankings
  module Music
    module Artists
      class Calculator < ItemRankings::Calculator
        def call
          artists_with_scores = calculate_all_artist_scores
          update_ranked_items_from_scores(artists_with_scores)

          Result.new(success?: true, data: artists_with_scores, errors: [])
        rescue => error
          Result.new(success?: false, data: nil, errors: [error.message])
        end

        protected

        def list_type
          raise NotImplementedError, "Artists use aggregation from album/song rankings, not list-based ranking"
        end

        def item_type
          "Music::Artist"
        end

        private

        def calculate_all_artist_scores
          album_config = ::Music::Albums::RankingConfiguration.default_primary
          song_config = ::Music::Songs::RankingConfiguration.default_primary

          return [] unless album_config && song_config

          artists = []
          ::Music::Artist.includes(:albums, :songs).find_each do |artist|
            score = calculate_artist_score(artist, album_config, song_config)
            artists << {id: artist.id, score: score} if score > 0
          end

          artists.sort_by { |a| -a[:score] }
        end

        def calculate_artist_score(artist, album_config, song_config)
          album_scores = RankedItem
            .where(item_type: "Music::Album", item_id: artist.albums.pluck(:id))
            .where(ranking_configuration_id: album_config.id)
            .sum(:score)

          song_scores = RankedItem
            .where(item_type: "Music::Song", item_id: artist.songs.pluck(:id))
            .where(ranking_configuration_id: song_config.id)
            .sum(:score)

          album_scores + song_scores
        end

        def update_ranked_items_from_scores(artists_with_scores)
          ActiveRecord::Base.transaction do
            ranked_items_data = []

            artists_with_scores.each_with_index do |artist_data, index|
              next if artist_data[:score].zero?

              ranked_items_data << {
                ranking_configuration_id: ranking_configuration.id,
                item_id: artist_data[:id],
                item_type: "Music::Artist",
                rank: index + 1,
                score: artist_data[:score],
                created_at: Time.current
              }
            end

            if ranked_items_data.any?
              RankedItem.upsert_all(
                ranked_items_data,
                unique_by: [:item_id, :item_type, :ranking_configuration_id],
                update_only: [:rank, :score]
              )
            end

            current_artist_ids = artists_with_scores.map { |a| a[:id] }
            ranking_configuration.ranked_items
              .where(item_type: "Music::Artist")
              .where.not(item_id: current_artist_ids)
              .delete_all
          end
        end
      end
    end
  end
end
