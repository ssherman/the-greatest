require "csv"

# Read-only "My Lists" surface (user-lists Phase A). Global routes resolve
# Current.domain to the relevant UserList STI subclasses and pick the per-domain
# layout dynamically. All actions are owner-only and never cached. Write actions
# (create/edit/reorder/remove/delete) are Phase B (user-lists-02f).
class MyListsController < ApplicationController
  include Pagy::Method
  include Cacheable

  layout :resolve_layout

  before_action :require_signed_in!
  before_action :prevent_caching

  # GET /my/lists
  # Per-domain dashboard: the signed-in user's lists for Current.domain, defaults
  # first (in subclass then list_type order) then custom, with item counts from a
  # single grouped query. Always renders (defaults are auto-created at signup).
  def index
    types = UserList.subclasses_for(Current.domain).map(&:name)
    lists = current_user.user_lists.where(type: types).to_a

    @item_counts = UserListItem.where(user_list_id: lists.map(&:id))
      .group(:user_list_id).count

    defaults, custom = lists.partition(&:default?)
    @user_lists =
      defaults.sort_by { |l| [types.index(l.type), l.list_type_before_type_cast] } +
      custom.sort_by { |l| l.name.downcase }
  end

  # GET /my/lists/:id(.csv)
  # Owner-only read view. Renders items in the persisted view_mode, ordered by
  # position (default) or by the listable's primary ranking configuration
  # (?sort=ranking, unranked last, degrades to position when no config). CSV is
  # unpaginated and follows the current sort.
  def show
    # Scope to the current domain's subclasses so a list from another domain
    # (e.g. a games list opened on the music host) 404s rather than rendering in
    # the wrong layout. Non-domain/non-owner both hide existence via 404.
    types = UserList.subclasses_for(Current.domain).map(&:name)
    @list = current_user.user_lists.where(type: types).find(params[:id])
    authorize @list, :show?, policy_class: UserListPolicy

    @ranking_config = @list.class.ranking_configuration_class&.default_primary
    @ranking_available = @ranking_config.present?
    @sort = (params[:sort] == "ranking" && @ranking_available) ? "ranking" : "position"

    persist_view_mode
    @view_mode = @list.view_mode

    scope = @list.user_list_items.ordered.includes(listable: @list.class.listable_display_includes)
    collection = (@sort == "ranking") ? ranking_sorted(scope.to_a) : scope

    respond_to do |format|
      format.html { @pagy, @items = pagy(collection, limit: 100) }
      format.csv do
        items = collection.is_a?(Array) ? collection : collection.to_a
        send_data build_csv(items),
          type: "text/csv; charset=utf-8",
          filename: csv_filename,
          disposition: "attachment"
      end
    end
  end

  private

  # Music shares the music layout; books has no layout yet, so unknown domains
  # fall back to it rather than referencing a nonexistent books/application.
  def resolve_layout
    case Current.domain
    when :games then "games/application"
    when :movies then "movies/application"
    else "music/application"
    end
  end

  # Persist the view_mode when the owner switches it via the query param.
  def persist_view_mode
    requested = params[:view_mode]
    return if requested.blank? || !UserList.view_modes.key?(requested)
    @list.update!(view_mode: requested) unless @list.view_mode == requested
  end

  # Orders the list's items by the listable's primary ranking, unranked last.
  # Only the items in this list are looked up (not the whole ranked table).
  def ranking_sorted(items)
    return items if @ranking_config.nil?
    ids = items.map(&:listable_id)
    ranks = @ranking_config.ranked_items.where(item_id: ids).pluck(:item_id, :rank).to_h
    items.sort_by { |i| [ranks[i.listable_id] ? 0 : 1, ranks[i.listable_id] || 0] }
  end

  # CSV (UTF-8 + BOM for Excel). Columns vary per listable; the Completed On
  # column appears only on lists whose list_type supports a completion date.
  def build_csv(items)
    listable_name = @list.class.listable_class.name
    show_completed = @list.completed_on_enabled?
    "\uFEFF" + CSV.generate do |csv|
      csv << csv_headers(listable_name, show_completed)
      items.each { |item| csv << csv_row(item, listable_name, show_completed) }
    end
  end

  def csv_headers(listable_name, show_completed)
    headers =
      case listable_name
      when "Music::Album", "Music::Song" then ["Position", "Title", "Artists", "Year"]
      else ["Position", "Title", "Year"]
      end
    show_completed ? headers + ["Completed On"] : headers
  end

  def csv_row(item, listable_name, show_completed)
    listable = item.listable
    row =
      case listable_name
      when "Music::Album", "Music::Song"
        [item.position, listable.title, artist_names(listable), listable.release_year]
      else
        [item.position, listable.title, listable.release_year]
      end
    show_completed ? row + [item.completed_on&.iso8601] : row
  end

  def artist_names(listable)
    listable.artists.map(&:name).join(", ")
  end

  def csv_filename
    "#{@list.name.parameterize}-#{Date.current.iso8601}.csv"
  end
end
