# frozen_string_literal: true

class Admin::Music::Songs::ListItemsActionsController < Admin::Music::BaseController
  before_action :set_list
  before_action :set_item, only: [:verify, :metadata, :manual_link, :link_musicbrainz_recording, :link_musicbrainz_artist, :modal]

  # GET /admin/songs/:list_id/items/:id/modal/:modal_type
  # Loads modal content on-demand for the shared modal component.
  # Returns content wrapped in turbo_frame_tag for Turbo Frame replacement.
  VALID_MODAL_TYPES = %w[edit_metadata link_song search_musicbrainz_recordings search_musicbrainz_artists].freeze

  def modal
    modal_type = params[:modal_type]

    unless VALID_MODAL_TYPES.include?(modal_type)
      render partial: "admin/music/songs/list_items_actions/modals/error",
        locals: {message: "Invalid modal type"}
      return
    end

    render partial: "admin/music/songs/list_items_actions/modals/#{modal_type}",
      locals: {item: @item, list: @list}
  end

  def verify
    # Clear ai_match_invalid when admin verifies - this overrides AI decision
    @item.update!(
      verified: true,
      metadata: @item.metadata.except("ai_match_invalid")
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Item verified"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Item verified" }
    end
  end

  def metadata
    metadata_json = params.dig(:list_item, :metadata_json)

    begin
      metadata = JSON.parse(metadata_json)
    rescue JSON::ParserError => e
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Invalid JSON: #{e.message}"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Invalid JSON: #{e.message}" }
      end
      return
    end

    @item.update!(metadata: metadata)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Metadata updated successfully"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Metadata updated successfully" }
    end
  end

  def manual_link
    song_id = params[:song_id]

    unless song_id.present?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Please select a song"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Please select a song" }
      end
      return
    end

    song = Music::Song.find_by(id: song_id)

    unless song
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Song not found"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Song not found" }
      end
      return
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

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Song linked successfully"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Song linked successfully" }
    end
  end

  def link_musicbrainz_recording
    mb_recording_id = params[:mb_recording_id]

    unless mb_recording_id.present?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Please select a recording"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Please select a recording" }
      end
      return
    end

    search = Music::Musicbrainz::Search::RecordingSearch.new
    response = search.lookup_by_mbid(mb_recording_id)

    if response[:success] && response[:data]["recordings"]&.any?
      recording = response[:data]["recordings"].first

      artist_names = extract_artist_names_from_recording(recording)
      year = extract_year_from_recording(recording)

      # Clear ai_match_invalid when admin manually links MusicBrainz - this overrides AI decision
      @item.metadata = @item.metadata.except("ai_match_invalid").merge(
        "mb_recording_id" => mb_recording_id,
        "mb_recording_name" => recording["title"],
        "mb_artist_names" => artist_names,
        "mb_release_year" => year,
        "musicbrainz_match" => true,
        "manual_musicbrainz_link" => true
      )
      @item.verified = true

      # Also link to existing song if one exists with this recording ID
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
        # Clear stale listable when linking to a MusicBrainz recording that has no local song.
        # This ensures the import step will create the new song rather than keeping a mismatched link.
        @item.listable = nil
        @item.metadata = @item.metadata.except("song_id", "song_name")
      end

      @item.save!

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
            turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
            turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "MusicBrainz recording linked successfully"})
          ]
        end
        format.html { redirect_to review_step_path, notice: "MusicBrainz recording linked successfully" }
      end
    else
      error_message = response[:errors]&.first || "Recording not found"
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: error_message}
          )
        end
        format.html { redirect_to review_step_path, alert: error_message }
      end
    end
  end

  def link_musicbrainz_artist
    mb_artist_id = params[:mb_artist_id]

    unless mb_artist_id.present?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Please select an artist"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Please select an artist" }
      end
      return
    end

    search = Music::Musicbrainz::Search::ArtistSearch.new
    response = search.lookup_by_mbid(mb_artist_id)

    if response[:success] && response[:data]["artists"]&.any?
      artist = response[:data]["artists"].first
      artist_name = artist["name"]

      # Replace mb_artist_ids and mb_artist_names with single-element arrays
      @item.metadata = @item.metadata.merge(
        "mb_artist_ids" => [mb_artist_id],
        "mb_artist_names" => [artist_name]
      )
      @item.save!

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
            turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
            turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "MusicBrainz artist linked successfully"})
          ]
        end
        format.html { redirect_to review_step_path, notice: "MusicBrainz artist linked successfully" }
      end
    else
      error_message = response[:errors]&.first || "Artist not found"
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: error_message}
          )
        end
        format.html { redirect_to review_step_path, alert: error_message }
      end
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
    response = search.search_by_artist_mbid_and_title(artist_mbid, query, limit: 10)

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

  def musicbrainz_artist_search
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

  def set_list
    @list = Music::Songs::List.find(params[:list_id])
  end

  def set_item
    @item = @list.list_items.includes(listable: :artists).find(params[:id])
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

  # Format artist display as "Artist Name (Type from Location)"
  # e.g., "The Beatles (Group from Liverpool)"
  def format_artist_display(artist)
    name = artist["name"]
    type = artist["type"]
    country = artist["country"]
    disambiguation = artist["disambiguation"]

    # Build location string from country or disambiguation
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
