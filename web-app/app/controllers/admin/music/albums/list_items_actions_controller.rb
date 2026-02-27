# frozen_string_literal: true

class Admin::Music::Albums::ListItemsActionsController < Admin::Music::BaseController
  include ListItemsActions

  # Album-specific modal types
  VALID_MODAL_TYPES = %w[edit_metadata link_album search_musicbrainz_releases search_musicbrainz_artists].freeze

  def skip
    @item.update!(
      verified: false,
      metadata: @item.metadata.merge("skipped" => true)
    )

    render_item_update_success("Item skipped")
  end

  def manual_link
    album_id = params[:album_id]

    unless album_id.present?
      return render_modal_error("Please select an album")
    end

    album = Music::Album.find_by(id: album_id)

    unless album
      return render_modal_error("Album not found")
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

    render_item_update_success("Album linked")
  end

  def link_musicbrainz_release
    mb_release_group_id = params[:mb_release_group_id]

    unless mb_release_group_id.present?
      return render_modal_error("Please select a release group")
    end

    # Look up the release group from MusicBrainz
    search = Music::Musicbrainz::Search::ReleaseGroupSearch.new
    response = search.lookup_by_release_group_mbid(mb_release_group_id)

    unless response[:success] && response[:data]["release-groups"]&.any?
      return render_modal_error("Release group not found in MusicBrainz")
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

    render_item_update_success("MusicBrainz release linked")
  end

  def link_musicbrainz_artist
    mb_artist_id = params[:mb_artist_id]

    unless mb_artist_id.present?
      return render_modal_error("Please select an artist")
    end

    # Look up the artist from MusicBrainz
    search = Music::Musicbrainz::Search::ArtistSearch.new
    response = search.lookup_by_mbid(mb_artist_id)

    unless response[:success] && response[:data]["artists"]&.any?
      return render_modal_error("Artist not found in MusicBrainz")
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

    render_item_update_success("Artist updated - please search for releases")
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

    render_item_update_success("Item cleared for re-enrichment")
  end

  def queue_import
    @item.update!(
      verified: true,
      metadata: @item.metadata.merge("queued_for_import" => true).except("ai_match_invalid")
    )

    render_item_update_success("Item queued for import")
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
    response = search.search_by_artist_mbid_and_title(artist_mbid, query, limit: 20)

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

  private

  # Override to add album-specific actions that need @item loaded
  def item_actions_for_set_item
    super + [:skip, :manual_link, :link_musicbrainz_release, :link_musicbrainz_artist, :re_enrich, :queue_import]
  end

  def list_class
    Music::Albums::List
  end

  def partials_path
    "admin/music/albums/list_items_actions"
  end

  def valid_modal_types
    VALID_MODAL_TYPES
  end

  def shared_modal_component_class
    Admin::Music::Albums::Wizard::SharedModalComponent
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
end
