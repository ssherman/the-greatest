# frozen_string_literal: true

module Search
  # Single source of truth for the "add item from a list page" typeahead (02e):
  # maps a UserListItem +listable_type+ to its per-domain OpenSearch autocomplete
  # service and serializes matched records into {value:, text:} rows for the
  # dropdown. Only types backed by a search index are searchable; everything else
  # (e.g. Movies::Movie, which has no index yet) is treated as unsupported.
  #
  # Used by both ListableSearchesController (the JSON endpoint) and
  # UserLists::Show::AddItemComponent (which renders the box only when the list's
  # listable type is searchable), so the supported-type list lives in one place.
  class ListableAutocomplete
    DEFAULT_LIMIT = 10

    CONFIGS = {
      "Music::Album" => {
        service: ::Search::Music::Search::AlbumAutocomplete,
        model: ::Music::Album,
        includes: [:artists]
      },
      "Music::Song" => {
        service: ::Search::Music::Search::SongAutocomplete,
        model: ::Music::Song,
        includes: [:artists]
      },
      "Games::Game" => {
        service: ::Search::Games::Search::GameAutocomplete,
        model: ::Games::Game,
        includes: []
      }
    }.freeze

    # Whether a listable type can be searched (has an autocomplete index).
    def self.searchable?(listable_type)
      CONFIGS.key?(listable_type.to_s)
    end

    # Returns [{value: id, text: "label"}] for the typeahead dropdown, in the
    # search service's relevance order. Blank/unknown type or blank query → [].
    def self.search(listable_type:, query:, limit: DEFAULT_LIMIT)
      config = CONFIGS[listable_type.to_s]
      return [] if config.nil?

      results = config[:service].call(query.to_s, size: limit)
      ids = results.map { |r| r[:id].to_i }
      return [] if ids.empty?

      scope = config[:model].where(id: ids)
      scope = scope.includes(*config[:includes]) if config[:includes].any?

      scope
        .in_order_of(:id, ids)
        .map { |record| {value: record.id, text: label_for(listable_type.to_s, record)} }
    end

    # Dropdown label per type: "Title — Artists" for music, "Title (year)" for games.
    def self.label_for(listable_type, record)
      case listable_type
      when "Music::Album", "Music::Song"
        artists = record.artists.map(&:name).join(", ")
        artists.present? ? "#{record.title} — #{artists}" : record.title
      when "Games::Game"
        record.release_year.present? ? "#{record.title} (#{record.release_year})" : record.title
      else
        record.title
      end
    end
    private_class_method :label_for
  end
end
