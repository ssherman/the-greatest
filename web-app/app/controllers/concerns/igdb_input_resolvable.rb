# frozen_string_literal: true

module IgdbInputResolvable
  extend ActiveSupport::Concern

  IGDB_URL_PATTERN = %r{\Ahttps?://(?:www\.)?igdb\.com/games/([a-z0-9][a-z0-9-]*[a-z0-9])}i

  # Parses raw input as either a numeric IGDB ID or an IGDB URL.
  # Returns [igdb_id, result] on success, or [nil, error_message] on failure.
  def resolve_igdb_input(raw_input)
    search = Games::Igdb::Search::GameSearch.new

    if raw_input.match?(/\A\d+\z/)
      igdb_id = raw_input.to_i
      result = search.find_with_details(igdb_id)
      [igdb_id, result]
    elsif (match = raw_input.match(IGDB_URL_PATTERN))
      slug = match[1]
      slug_result = search.find_by_slug(slug)

      unless slug_result[:success] && slug_result[:data]&.any?
        return [nil, "IGDB game not found for slug: #{slug}"]
      end

      igdb_id = slug_result[:data].first["id"]
      [igdb_id, slug_result]
    else
      [nil, "Invalid IGDB ID or URL. Enter a numeric ID (e.g., 12515) or IGDB URL."]
    end
  end

  # Formats an IGDB game hash into a JSON-ready hash for autocomplete responses.
  def format_igdb_game_for_autocomplete(g)
    involved_companies = g["involved_companies"] || []
    developers = involved_companies
      .select { |ic| ic["developer"] }
      .map { |ic| ic.dig("company", "name") }
      .compact

    release_year = if g["first_release_date"]
      Time.at(g["first_release_date"]).year
    end

    cover_url = if g.dig("cover", "image_id")
      "https://images.igdb.com/igdb/image/upload/t_thumb/#{g["cover"]["image_id"]}.jpg"
    end

    {
      igdb_id: g["id"],
      name: g["name"],
      developers: developers,
      release_year: release_year,
      cover_url: cover_url,
      value: g["id"],
      text: "#{g["name"]}#{" - #{developers.join(", ")}" if developers.any?}#{" (#{release_year})" if release_year}"
    }
  end
end
