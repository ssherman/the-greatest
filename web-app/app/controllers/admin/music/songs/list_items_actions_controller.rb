# frozen_string_literal: true

class Admin::Music::Songs::ListItemsActionsController < Admin::Music::BaseController
  include ListItemsActions
  include MusicbrainzInputResolvable

  # Song-specific modal types
  VALID_MODAL_TYPES = %w[edit_metadata link_song search_musicbrainz_recordings search_musicbrainz_artists link_musicbrainz_url].freeze

  def manual_link
    song_id = params[:song_id]

    unless song_id.present?
      return render_modal_error("Please select a song")
    end

    song = Music::Song.find_by(id: song_id)

    unless song
      return render_modal_error("Song not found")
    end

    # Clear ai_match_invalid when admin manually links - this overrides AI decision
    @item.update!(
      listable: song,
      verified: true,
      metadata: @item.metadata.except("ai_match_invalid").merge(
        "song_id" => song.id,
        "song_name" => song.title,
        "manual_link" => true
      )
    )

    render_item_update_success("Song linked successfully")
  end

  def link_musicbrainz_recording
    mb_recording_id = params[:mb_recording_id]

    unless mb_recording_id.present?
      return render_modal_error("Please select a recording")
    end

    perform_link_musicbrainz_recording(mb_recording_id)
  end

  def link_musicbrainz_url
    raw_input = params[:musicbrainz_input].to_s.strip

    unless raw_input.present?
      return render_modal_error("Please enter a MusicBrainz URL or ID")
    end

    mbid, error = resolve_musicbrainz_input(raw_input, expected_type: "recording")
    return render_modal_error(error) if error

    perform_link_musicbrainz_recording(mbid)
  end

  def link_musicbrainz_artist
    mb_artist_id = params[:mb_artist_id]

    unless mb_artist_id.present?
      return render_modal_error("Please select an artist")
    end

    search = Music::Musicbrainz::Search::ArtistSearch.new
    response = search.lookup_by_mbid(mb_artist_id)

    if response[:success] && response[:data]["artists"]&.any?
      artist = response[:data]["artists"].first
      artist_name = artist["name"]

      # Clear stale recording metadata since it was matched against the old artist
      # Also clear any linked song since it may no longer be correct
      @item.metadata = @item.metadata.except(
        "mb_recording_id",
        "mb_recording_name",
        "mb_release_year",
        "musicbrainz_match",
        "manual_musicbrainz_link",
        "song_id",
        "song_name"
      ).merge(
        "mb_artist_ids" => [mb_artist_id],
        "mb_artist_names" => [artist_name]
      )
      @item.listable = nil
      @item.verified = false
      @item.save!

      render_item_update_success("MusicBrainz artist linked successfully")
    else
      error_message = response[:errors]&.first || "Artist not found"
      render_modal_error(error_message)
    end
  end

  def musicbrainz_recording_search
    item_id = params[:item_id]
    query = params[:q]

    # Item ID is required - we need the artist MBID from metadata
    return render json: [] if item_id.blank?

    item = @list.list_items.find_by(id: item_id)
    return render json: [] unless item

    # MusicBrainz search only works with an artist MBID
    mb_artist_ids = Array(item.metadata["mb_artist_ids"])
    return render json: [] if mb_artist_ids.empty?

    # Use the first artist MBID for searching
    artist_mbid = mb_artist_ids.first
    return render json: [] if query.blank? || query.length < 2

    search = Music::Musicbrainz::Search::RecordingSearch.new
    response = search.search_by_artist_mbid_and_title(artist_mbid, query, limit: 20)

    return render json: [] unless response[:success]

    recordings = response[:data]["recordings"] || []
    render json: recordings.map { |r|
      artist_names = extract_artist_names_from_recording(r)
      year = extract_year_from_recording(r)
      {
        value: r["id"],
        text: "#{r["title"]} - #{artist_names}#{" (#{year})" if year}"
      }
    }
  end

  private

  # Override to add song-specific actions that need @item loaded
  def item_actions_for_set_item
    super + [:manual_link, :link_musicbrainz_recording, :link_musicbrainz_artist, :link_musicbrainz_url]
  end

  def perform_link_musicbrainz_recording(mb_recording_id)
    search = Music::Musicbrainz::Search::RecordingSearch.new
    response = search.lookup_by_mbid(mb_recording_id)

    unless response[:success] && response[:data]["recordings"]&.any?
      error_message = response[:errors]&.first || "Recording not found in MusicBrainz"
      return render_modal_error(error_message)
    end

    recording = response[:data]["recordings"].first

    artist_names = extract_artist_names_from_recording(recording)
    year = extract_year_from_recording(recording)

    @item.metadata = @item.metadata.except("ai_match_invalid").merge(
      "mb_recording_id" => mb_recording_id,
      "mb_recording_name" => recording["title"],
      "mb_artist_names" => artist_names,
      "mb_release_year" => year,
      "musicbrainz_match" => true,
      "manual_musicbrainz_link" => true
    )
    @item.verified = true

    song = Music::Song.joins(:identifiers).find_by(
      identifiers: {
        identifier_type: :music_musicbrainz_recording_id,
        value: mb_recording_id
      }
    )

    if song
      @item.listable = song
      @item.metadata = @item.metadata.merge(
        "song_id" => song.id,
        "song_name" => song.title
      )
    else
      @item.listable = nil
      @item.metadata = @item.metadata.except("song_id", "song_name")
    end

    @item.save!
    render_item_update_success("MusicBrainz recording linked successfully")
  end

  def list_class
    Music::Songs::List
  end

  def partials_path
    "admin/music/songs/list_items_actions"
  end

  def valid_modal_types
    VALID_MODAL_TYPES
  end

  def shared_modal_component_class
    Admin::Music::Songs::Wizard::SharedModalComponent
  end

  def review_step_path
    step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")
  end

  def extract_artist_names_from_recording(recording)
    artist_credits = recording["artist-credit"] || []
    artist_credits.map { |ac| ac.dig("artist", "name") || ac["name"] }.compact.join(", ")
  end

  def extract_year_from_recording(recording)
    first_release = recording["first-release-date"]
    return nil unless first_release.present?
    first_release.split("-").first.to_i
  end
end
