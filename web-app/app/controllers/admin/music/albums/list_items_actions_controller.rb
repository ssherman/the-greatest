# frozen_string_literal: true

class Admin::Music::Albums::ListItemsActionsController < Admin::Music::BaseController
  before_action :set_list
  before_action :set_item, only: [:verify, :skip, :metadata, :manual_link, :link_musicbrainz_release, :link_musicbrainz_artist, :modal, :re_enrich, :queue_import]

  # GET /admin/albums/:list_id/items/:id/modal/:modal_type
  # Loads modal content on-demand for the shared modal component.
  # Returns content wrapped in turbo_frame_tag for Turbo Frame replacement.
  VALID_MODAL_TYPES = %w[edit_metadata link_album search_musicbrainz_releases search_musicbrainz_artists].freeze

  def modal
    modal_type = params[:modal_type]

    unless VALID_MODAL_TYPES.include?(modal_type)
      render partial: "admin/music/albums/list_items_actions/modals/error",
        locals: {message: "Invalid modal type"}
      return
    end

    render partial: "admin/music/albums/list_items_actions/modals/#{modal_type}",
      locals: {item: @item, list: @list}
  end

  def verify
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

  def skip
    @item.update!(
      verified: false,
      metadata: @item.metadata.merge("skipped" => true)
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Item skipped"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Item skipped" }
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
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
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
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Metadata updated"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Metadata updated" }
    end
  end

  def manual_link
    album_id = params[:album_id]

    unless album_id.present?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Please select an album"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Please select an album" }
      end
      return
    end

    album = Music::Album.find_by(id: album_id)

    unless album
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Album not found"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Album not found" }
      end
      return
    end

    @item.update!(
      listable: album,
      verified: true,
      metadata: @item.metadata.except("ai_match_invalid").merge(
        "album_id" => album.id,
        "album_name" => album.title,
        "manual_link" => true
      )
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Album linked"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Album linked" }
    end
  end

  def link_musicbrainz_release
    mb_release_group_id = params[:mb_release_group_id]

    unless mb_release_group_id.present?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Please select a release group"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Please select a release group" }
      end
      return
    end

    # Look up the release group from MusicBrainz
    search = Music::Musicbrainz::Search::ReleaseGroupSearch.new
    response = search.lookup_by_release_group_mbid(mb_release_group_id)

    unless response[:success] && response[:data]["release-groups"]&.any?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Release group not found in MusicBrainz"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Release group not found" }
      end
      return
    end

    release_group = response[:data]["release-groups"].first
    release_group_name = release_group["title"]
    artist_credits = release_group["artist-credit"] || []
    artist_names = artist_credits.map { |ac| ac.dig("artist", "name") || ac["name"] }.compact
    first_release_date = release_group["first-release-date"]
    release_year = first_release_date&.split("-")&.first&.to_i

    # Check if we have an existing album with this MusicBrainz ID
    album = Music::Album.joins(:identifiers).find_by(
      identifiers: {
        identifier_type: :music_musicbrainz_release_group_id,
        value: mb_release_group_id
      }
    )

    if album
      @item.listable = album
      @item.metadata = @item.metadata.merge(
        "album_id" => album.id,
        "album_name" => album.title
      )
    else
      # Clear any existing listable - will be created during import
      @item.listable = nil
      @item.metadata = @item.metadata.except("album_id", "album_name")
    end

    @item.metadata = @item.metadata.merge(
      "mb_release_group_id" => mb_release_group_id,
      "mb_release_group_name" => release_group_name,
      "mb_artist_names" => artist_names,
      "mb_release_year" => release_year,
      "musicbrainz_match" => true,
      "manual_musicbrainz_link" => true
    ).except("ai_match_invalid")
    @item.verified = true
    @item.save!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "MusicBrainz release linked"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "MusicBrainz release linked" }
    end
  end

  def link_musicbrainz_artist
    mb_artist_id = params[:mb_artist_id]

    unless mb_artist_id.present?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Please select an artist"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Please select an artist" }
      end
      return
    end

    # Look up the artist from MusicBrainz
    search = Music::Musicbrainz::Search::ArtistSearch.new
    response = search.lookup_by_artist_mbid(mb_artist_id)

    unless response[:success] && response[:data]["artists"]&.any?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID,
            partial: "error_message",
            locals: {message: "Artist not found in MusicBrainz"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Artist not found" }
      end
      return
    end

    artist = response[:data]["artists"].first
    artist_name = artist["name"]

    # Clear stale release group data when artist changes
    @item.metadata = @item.metadata.except(
      "mb_release_group_id",
      "mb_release_group_name",
      "mb_release_year",
      "musicbrainz_match",
      "manual_musicbrainz_link",
      "album_id",
      "album_name"
    ).merge(
      "mb_artist_ids" => [mb_artist_id],
      "mb_artist_names" => [artist_name]
    )
    @item.listable = nil
    @item.verified = false
    @item.save!

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Artist updated - please search for releases"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Artist updated" }
    end
  end

  def re_enrich
    # Re-run enrichment for this specific item
    @item.update!(
      verified: false,
      listable: nil,
      metadata: @item.metadata.except(
        "mb_release_group_id", "mb_release_group_name", "mb_artist_ids", "mb_artist_names",
        "mb_release_year", "musicbrainz_match", "manual_musicbrainz_link",
        "opensearch_match", "opensearch_score", "album_id", "album_name",
        "ai_match_invalid"
      )
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Item cleared for re-enrichment"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Item cleared for re-enrichment" }
    end
  end

  def queue_import
    @item.update!(
      verified: true,
      metadata: @item.metadata.merge("queued_for_import" => true).except("ai_match_invalid")
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Item queued for import"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Item queued for import" }
    end
  end

  # JSON endpoint for MusicBrainz release group autocomplete
  def musicbrainz_release_search
    item_id = params[:item_id]
    query = params[:q]

    return render json: [] if item_id.blank?

    item = @list.list_items.find_by(id: item_id)
    return render json: [] unless item

    mb_artist_ids = Array(item.metadata["mb_artist_ids"])
    return render json: [] if mb_artist_ids.empty?

    artist_mbid = mb_artist_ids.first
    return render json: [] if query.blank? || query.length < 2

    search = Music::Musicbrainz::Search::ReleaseGroupSearch.new
    response = search.search_by_artist_mbid_and_title(artist_mbid, query, limit: 10)

    return render json: [] unless response[:success]

    release_groups = response[:data]["release-groups"] || []
    render json: release_groups.map { |rg|
      artist_names = extract_artist_names_from_release_group(rg)
      year = extract_year_from_release_group(rg)
      primary_type = rg["primary-type"] || "Unknown"

      {
        value: rg["id"],
        text: "#{rg["title"]} - #{artist_names}#{" (#{year})" if year} [#{primary_type}]"
      }
    }
  end

  # JSON endpoint for MusicBrainz artist autocomplete
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

  # Bulk actions
  def bulk_verify
    item_ids = params[:item_ids] || []
    items = @list.list_items.where(id: item_ids)

    items.update_all(verified: true)
    items.each do |item|
      item.update!(metadata: item.metadata.except("ai_match_invalid"))
    end

    redirect_to review_step_path, notice: "#{items.count} items verified"
  end

  def bulk_skip
    item_ids = params[:item_ids] || []
    items = @list.list_items.where(id: item_ids)

    items.each do |item|
      item.update!(verified: false, metadata: item.metadata.merge("skipped" => true))
    end

    redirect_to review_step_path, notice: "#{items.count} items skipped"
  end

  def bulk_delete
    item_ids = params[:item_ids] || []
    deleted_count = @list.list_items.where(id: item_ids).destroy_all.count

    redirect_to review_step_path, notice: "#{deleted_count} items deleted"
  end

  private

  def set_list
    @list = Music::Albums::List.find(params[:list_id])
  end

  def set_item
    @item = @list.list_items.includes(listable: :artists).find(params[:id])
  end

  def review_step_path
    step_admin_albums_list_wizard_path(list_id: @list.id, step: "review")
  end

  def extract_artist_names_from_release_group(release_group)
    artist_credits = release_group["artist-credit"] || []
    artist_credits.map { |ac| ac.dig("artist", "name") || ac["name"] }.compact.join(", ")
  end

  def extract_year_from_release_group(release_group)
    first_release = release_group["first-release-date"]
    return nil unless first_release.present?
    first_release.split("-").first.to_i
  end

  # Format artist as "Artist Name (Type from Location)"
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
