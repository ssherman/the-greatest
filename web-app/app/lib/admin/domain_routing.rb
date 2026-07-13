module Admin
  module DomainRouting
    URL_HELPERS = Rails.application.routes.url_helpers

    ENTITIES = {
      "Music::Artist" => {domain: :music, path: ->(r) { URL_HELPERS.admin_artist_path(r) }},
      "Music::Album" => {domain: :music, path: ->(r) { URL_HELPERS.admin_album_path(r) }},
      "Music::Song" => {domain: :music, path: ->(r) { URL_HELPERS.admin_song_path(r) }},
      "Games::Game" => {domain: :games, path: ->(r) { URL_HELPERS.admin_games_game_path(r) }},
      "Games::Company" => {domain: :games, path: ->(r) { URL_HELPERS.admin_games_company_path(r) }}
    }.freeze

    NESTED_PARENTS = {
      music: {
        artist_id: "Music::Artist",
        album_id: "Music::Album",
        song_id: "Music::Song"
      },
      games: {
        game_id: "Games::Game",
        company_id: "Games::Company"
      }
    }.freeze

    LISTS = {
      "Music::Albums::List" => {
        domain: :music,
        listable_type: "Music::Album",
        item_label: "Album",
        path: ->(l) { URL_HELPERS.admin_albums_list_path(l) },
        autocomplete_path: -> { URL_HELPERS.search_admin_albums_path }
      },
      "Music::Songs::List" => {
        domain: :music,
        listable_type: "Music::Song",
        item_label: "Song",
        path: ->(l) { URL_HELPERS.admin_songs_list_path(l) },
        autocomplete_path: -> { URL_HELPERS.search_admin_songs_path }
      },
      "Games::List" => {
        domain: :games,
        listable_type: "Games::Game",
        item_label: "Game",
        path: ->(l) { URL_HELPERS.admin_games_list_path(l) },
        autocomplete_path: -> { URL_HELPERS.search_admin_games_games_path }
      }
    }.freeze

    RANKING_CONFIGURATIONS = {
      "Music::Albums::RankingConfiguration" => {
        domain: :music,
        list_type: "Music::Albums::List",
        ranked_item_includes: {item: :artists},
        path: ->(rc) { URL_HELPERS.admin_albums_ranking_configuration_path(rc) }
      },
      "Music::Songs::RankingConfiguration" => {
        domain: :music,
        list_type: "Music::Songs::List",
        ranked_item_includes: {item: :artists},
        path: ->(rc) { URL_HELPERS.admin_songs_ranking_configuration_path(rc) }
      },
      "Music::Artists::RankingConfiguration" => {
        domain: :music,
        list_type: nil,
        ranked_item_includes: nil,
        path: ->(rc) { URL_HELPERS.admin_artists_ranking_configuration_path(rc) }
      },
      "Games::RankingConfiguration" => {
        domain: :games,
        list_type: "Games::List",
        ranked_item_includes: {item: :companies},
        path: ->(rc) { URL_HELPERS.admin_games_ranking_configuration_path(rc) }
      },
      "Books::RankingConfiguration" => {
        domain: :books,
        list_type: "Books::List",
        ranked_item_includes: nil,
        path: nil
      },
      "Movies::RankingConfiguration" => {
        domain: :movies,
        list_type: "Movies::List",
        ranked_item_includes: nil,
        path: nil
      }
    }.freeze

    PENALTIES = {
      "Global::Penalty" => "Global::Penalty",
      "Music::Penalty" => "Music::Penalty",
      "Games::Penalty" => "Games::Penalty",
      "Books::Penalty" => "Books::Penalty",
      "Movies::Penalty" => "Movies::Penalty"
    }.freeze

    class << self
      def domain_for(record_or_class)
        name = record_or_class.is_a?(Class) ? record_or_class.name : record_or_class.class.name

        ENTITIES.dig(name, :domain) ||
          LISTS.dig(name, :domain) ||
          RANKING_CONFIGURATIONS.dig(name, :domain)
      end

      def path_for(record)
        ENTITIES.dig(record.class.name, :path)&.call(record)
      end

      def list_config(list)
        resolve(LISTS[list.class.name], list)
      end

      def ranking_configuration_config(ranking_configuration)
        resolve(RANKING_CONFIGURATIONS[ranking_configuration.class.name], ranking_configuration)
      end

      def penalty_class(type_string)
        PENALTIES.fetch(type_string.to_s, "Global::Penalty").constantize
      end

      def parent_from_params(params, domain:)
        NESTED_PARENTS.fetch(domain.to_sym, {}).each do |param_key, class_name|
          id = params[param_key]
          return class_name.constantize.find(id) if id.present?
        end

        nil
      end

      private

      def resolve(config, record)
        return nil if config.nil?

        config.merge(
          path: record.persisted? ? config[:path]&.call(record) : nil,
          autocomplete_path: config[:autocomplete_path]&.call
        )
      end
    end
  end
end
