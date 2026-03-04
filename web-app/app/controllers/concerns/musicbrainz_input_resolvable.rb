# frozen_string_literal: true

module MusicbrainzInputResolvable
  extend ActiveSupport::Concern

  MUSICBRAINZ_URL_PATTERN = %r{\Ahttps?://(?:www\.)?musicbrainz\.org/([a-z-]+)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})}i
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # Parses raw input as a MusicBrainz URL or bare UUID.
  #
  # Returns a two-element array:
  #   Success: [String mbid, nil]
  #   Failure: [nil, String error_message]
  def resolve_musicbrainz_input(raw_input, expected_type:)
    if raw_input.match?(UUID_PATTERN)
      [raw_input, nil]
    elsif (match = raw_input.match(MUSICBRAINZ_URL_PATTERN))
      entity_type = match[1].downcase
      mbid = match[2]

      unless entity_type == expected_type
        return [nil, "Please use a MusicBrainz #{expected_type} URL (not #{entity_type})"]
      end

      [mbid, nil]
    else
      [nil, "Invalid MusicBrainz URL or ID. Enter a UUID or MusicBrainz URL."]
    end
  end
end
