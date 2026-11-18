# Read-only "My Lists" surface (user-lists Phase A). Global routes resolve
# Current.domain to the relevant UserList STI subclasses and pick the per-domain
# layout dynamically. index is owner-only (requires sign-in); show serves the
# owner or any viewer, including anonymous, when the list is public (404s
# otherwise via UserList.visible_to). Never cached. Write actions
# (create/edit/reorder/remove/delete) are Phase B (user-lists-02f).
class MyListsController < ApplicationController
  STREAM_ACTIONS = [:create].freeze

  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include DomainLayout

  layout :resolve_layout

  # show is reachable anonymously for public lists; visibility is enforced by the
  # visible_to scope below, which 404s rather than redirecting.
  before_action :require_signed_in!, only: [:index]
  before_action :require_signed_in_as_stream!, only: STREAM_ACTIONS
  before_action :prevent_caching

  # Write actions are submitted by Turbo forms, so every non-2xx answer must be a
  # Turbo Stream: an HTML error body on a non-2xx status replaces the whole page.
  # Scoped by action so index/show keep ApplicationController's HTML handling.
  rescue_from Pundit::NotAuthorizedError, with: :stream_forbidden
  rescue_from ActiveRecord::RecordNotFound, with: :stream_not_found
  rescue_from ActionController::InvalidAuthenticityToken, with: :stream_invalid_token

  # GET /my/lists
  # Per-domain dashboard: the signed-in user's lists for Current.domain, defaults
  # first (in subclass then list_type order) then custom, with item counts from a
  # single grouped query. Always renders (defaults are auto-created at signup).
  def index
    @types = UserList.subclasses_for(Current.domain)
    types = @types.map(&:name)
    lists = Services::UserLists::EnsureDefaults.call(
      user: current_user,
      domain: Current.domain,
      existing: current_user.user_lists.where(type: types).to_a
    )

    @item_counts = UserListItem.where(user_list_id: lists.map(&:id))
      .group(:user_list_id).count

    defaults, custom = lists.partition(&:default?)
    @user_lists =
      defaults.sort_by { |l| [types.index(l.type), l.list_type_before_type_cast] } +
      custom.sort_by { |l| l.name.downcase }
  end

  # POST /my/lists
  # Creates a custom list from the dashboard dialog. type must be one of this
  # domain's UserList subclasses. Success redirects (303) to the new list;
  # failure renders the errors into the dialog as a Turbo Stream.
  def create
    attrs = params.fetch(:user_list, {}).permit(:name, :description, :public, :type)
    klass = UserList.subclasses_for(Current.domain).find { |k| k.name == attrs[:type] }
    return render_new_list_errors(["Choose a valid list type"]) if klass.nil?

    result = Services::UserLists::CreateList.call(
      user: current_user,
      klass: klass,
      name: attrs[:name],
      description: attrs[:description].presence,
      public: ActiveModel::Type::Boolean.new.cast(attrs[:public]) || false
    )
    if result.success?
      redirect_to my_list_path(result.data[:list]), status: :see_other
    else
      render_new_list_errors(result.errors)
    end
  end

  # GET /my/lists/:id(.csv)
  # Read view for the owner, or any viewer (including anonymous) when the list
  # is public; UserList.visible_to 404s everything else. Renders items in the
  # persisted view_mode, ordered by position (default), by when each item was
  # added (?sort=added, newest first) or by the listable's primary ranking
  # configuration (?sort=ranking, unranked last, degrades to position when no
  # config). An unknown sort is position. CSV is unpaginated and follows the sort.
  def show
    # Scoped to the current domain's subclasses so a list from another domain
    # (e.g. a games list opened on the music host) 404s rather than rendering in
    # the wrong layout. visible_to keeps private non-owner reads at 404 too —
    # Pundit's rescue would redirect, leaking existence.
    types = UserList.subclasses_for(Current.domain).map(&:name)
    @list = UserList.where(type: types).visible_to(current_user).find(params[:id])
    authorize @list, :show?, policy_class: UserListPolicy
    @owner = @list.user_id == current_user&.id
    @indexable = false

    @ranking_config = @list.class.ranking_configuration_class&.default_primary
    @ranking_available = @ranking_config.present?
    @sort = resolve_sort

    persist_view_mode
    @view_mode = if @owner
      @list.view_mode
    else
      params[:view_mode].presence_in(UserList.view_modes.keys) || @list.view_mode
    end

    scope = @list.user_list_items.includes(listable: @list.class.listable_display_includes)
    scope = @list.class.catalog_items(scope) unless @owner
    scope = (@sort == "added") ? scope.reorder(created_at: :desc, id: :desc) : scope.ordered
    collection = (@sort == "ranking") ? ranking_sorted(scope.to_a) : scope

    respond_to do |format|
      format.html { @pagy, @items = pagy_path(collection, limit: 100) }
      format.csv do
        items = collection.is_a?(Array) ? collection : collection.to_a
        send_data CsvExports::UserList.call(list: @list, items: items).string,
          type: "text/csv; charset=utf-8",
          filename: csv_filename,
          disposition: "attachment"
      end
    end
  end

  private

  def stream_action?
    STREAM_ACTIONS.include?(action_name.to_sym)
  end

  def require_signed_in_as_stream!
    return if current_user
    render turbo_stream: turbo_stream.update("new-list-errors", "Sign in again to create a list"),
      status: :unauthorized
  end

  def render_new_list_errors(errors)
    render turbo_stream: turbo_stream.update("new-list-errors", errors.to_sentence),
      status: :unprocessable_entity
  end

  def stream_forbidden(exception)
    return user_not_authorized unless stream_action?
    render turbo_stream: [], status: :forbidden
  end

  def stream_not_found(exception)
    return render_not_found unless stream_action?
    render turbo_stream: [], status: :not_found
  end

  def stream_invalid_token(exception)
    raise exception unless stream_action?
    render turbo_stream: turbo_stream.update("new-list-errors", "Your session expired. Reload the page and try again"),
      status: :unprocessable_entity
  end

  # Persist the view_mode when the owner switches it via the query param. A
  # non-owner's param changes only their own render (see #show).
  def persist_view_mode
    return unless @owner
    requested = params[:view_mode]
    return if requested.blank? || !UserList.view_modes.key?(requested)
    @list.update!(view_mode: requested) unless @list.view_mode == requested
  end

  def resolve_sort
    case params[:sort]
    when "added" then "added"
    when "ranking" then @ranking_available ? "ranking" : "position"
    else "position"
    end
  end

  # Orders the list's items by the listable's primary ranking, unranked last.
  # Only the items in this list are looked up (not the whole ranked table).
  def ranking_sorted(items)
    return items if @ranking_config.nil?
    ids = items.map(&:listable_id)
    ranks = @ranking_config.ranked_items.where(item_id: ids).pluck(:item_id, :rank).to_h
    items.sort_by { |i| [ranks[i.listable_id] ? 0 : 1, ranks[i.listable_id] || 0] }
  end

  def csv_filename
    "#{@list.name.parameterize}-#{Date.current.iso8601}.csv"
  end
end
