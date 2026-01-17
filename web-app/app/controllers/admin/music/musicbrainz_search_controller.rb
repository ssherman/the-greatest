# frozen_string_literal: true

class Admin::Music::MusicbrainzSearchController < Admin::Music::BaseController
  # GET /admin/music/musicbrainz/artists
  # JSON endpoint for MusicBrainz artist autocomplete.
  # Returns array of {value: mbid, text: "Artist Name (Type from Location)"}
  def artists
    query = params[:q]
    return render json: [] if query.blank? || query.length < 2

    search = Music::Musicbrainz::Search::ArtistSearch.new
    response = search.search_by_name(query, limit: 10)

    return render json: [] unless response[:success]

    artists = response[:data]["artists"] || []
    render json: artists.map { |artist|
      {
        value: artist["id"],
        text: format_artist_display(artist)
      }
    }
  end

  private

  # Format artist display as "Artist Name (Type from Location)"
  # e.g., "The Beatles (Group from Liverpool)"
  def format_artist_display(artist)
    name = artist["name"]
    type = artist["type"]
    country = artist["country"]
    disambiguation = artist["disambiguation"]

    location = disambiguation.presence || country.presence

    if type.present? && location.present?
      "#{name} (#{type} from #{location})"
    elsif type.present?
      "#{name} (#{type})"
    elsif location.present?
      "#{name} (#{location})"
    else
      name
    end
  end
end
