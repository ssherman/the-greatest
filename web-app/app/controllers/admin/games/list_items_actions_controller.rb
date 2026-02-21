# frozen_string_literal: true

class Admin::Games::ListItemsActionsController < Admin::Games::BaseController
  include ListItemsActions

  # Games-specific modal types
  VALID_MODAL_TYPES = %w[edit_metadata link_game search_igdb_games].freeze

  def skip
    @item.update!(
      verified: false,
      metadata: @item.metadata.merge("skipped" => true)
    )

    render_item_update_success("Item skipped")
  end

  def manual_link
    game_id = params[:game_id]

    unless game_id.present?
      return render_modal_error("Please select a game")
    end

    game = Games::Game.find_by(id: game_id)

    unless game
      return render_modal_error("Game not found")
    end

    @item.update!(
      listable: game,
      verified: true,
      metadata: @item.metadata.except("ai_match_invalid").merge(
        "game_id" => game.id,
        "game_name" => game.title,
        "manual_link" => true
      )
    )

    render_item_update_success("Game linked")
  end

  def link_igdb_game
    igdb_id = params[:igdb_id]

    unless igdb_id.present?
      return render_modal_error("Please select a game")
    end

    igdb_id = igdb_id.to_i

    # Validate the IGDB ID exists by looking it up
    search = Games::Igdb::Search::GameSearch.new
    result = search.find_with_details(igdb_id)

    unless result[:success] && result[:data]&.any?
      return render_modal_error("IGDB game not found for ID #{igdb_id}")
    end

    igdb_game = result[:data].first
    igdb_name = igdb_game["name"]

    involved_companies = igdb_game["involved_companies"] || []
    igdb_developer_names = involved_companies
      .select { |ic| ic["developer"] }
      .map { |ic| ic.dig("company", "name") }
      .compact

    # Check if we have an existing local game with this IGDB ID
    game = Games::Game.with_igdb_id(igdb_id).first

    if game
      @item.listable = game
      @item.metadata = @item.metadata.merge(
        "game_id" => game.id,
        "game_name" => game.title
      )
    else
      # Clear any existing listable - will be created during import
      @item.listable = nil
      @item.metadata = @item.metadata.except("game_id", "game_name")
    end

    @item.metadata = @item.metadata.merge(
      "igdb_id" => igdb_id,
      "igdb_name" => igdb_name,
      "igdb_developer_names" => igdb_developer_names,
      "igdb_match" => true,
      "manual_igdb_link" => true
    ).except("ai_match_invalid")
    @item.verified = true
    @item.save!

    render_item_update_success("IGDB game linked")
  end

  def re_enrich
    @item.update!(
      verified: false,
      listable: nil,
      metadata: @item.metadata.except(
        "igdb_id", "igdb_name", "igdb_developer_names", "igdb_match",
        "manual_igdb_link", "opensearch_match", "opensearch_score",
        "game_id", "game_name", "ai_match_invalid"
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

  # JSON endpoint for IGDB game autocomplete
  def igdb_game_search
    query = params[:q]

    return render json: [] if query.blank? || query.length < 2

    search = Games::Igdb::Search::GameSearch.new
    result = search.search_by_name(query, limit: 10, fields: Services::Lists::Games::ListItemEnricher::IGDB_SEARCH_FIELDS)

    return render json: [] unless result[:success]

    games = result[:data] || []
    render json: games.map { |g|
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

  # Override to add games-specific actions that need @item loaded
  def item_actions_for_set_item
    super + [:skip, :manual_link, :link_igdb_game, :re_enrich, :queue_import]
  end

  def list_class
    Games::List
  end

  def partials_path
    "admin/games/list_items_actions"
  end

  def valid_modal_types
    VALID_MODAL_TYPES
  end

  def shared_modal_component_class
    Admin::Games::Wizard::SharedModalComponent
  end

  def review_step_path
    step_admin_games_list_wizard_path(list_id: @list.id, step: "review")
  end

  # Override to use games-specific eager loading (companies instead of artists)
  def set_item
    @item = @list.list_items.includes(listable: {game_companies: :company}).find(params[:id])
  end
end
