# Read-only "My Lists" surface (user-lists Phase A). Global routes resolve
# Current.domain to the relevant UserList STI subclasses and pick the per-domain
# layout dynamically. index is owner-only (requires sign-in); show serves the
# owner or any viewer, including anonymous, when the list is public (404s
# otherwise via UserList.visible_to). Never cached. The owner's list writes
# (create, edit, update, destroy) live here; item writes live elsewhere.
class MyListsController < ApplicationController
  STREAM_ACTIONS = [:create, :update, :destroy].freeze

  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include EditPageRows
  include DomainLayout

  layout :resolve_layout

  # show is reachable anonymously for public lists; visibility is enforced by the
  # visible_to scope below, which 404s rather than redirecting.
  before_action :require_signed_in!, only: [:index, :edit]
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
      mark_user_state_changed
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

  # GET /my/lists/:id/edit
  # The owner's Edit page. Shows every item, provisional books included (no
  # catalog filter), in position order. Non-owners 404.
  def edit
    @list = find_owned_list
    @indexable = false
    @pagy, @items = load_edit_rows(@list, page: requested_page)
    # Unlike a write's answer, a GET past the last page is a 404, not a clamp.
    raise ActiveRecord::RecordNotFound if requested_page > @pagy.last
  end

  # PATCH /my/lists/:id
  # Saves name / description / visibility. Answers as Turbo Streams: the form
  # is replaced in place with a "Saved" toast, or the error lands in the form.
  def update
    list = find_owned_list
    attrs, error = update_attrs(list)
    return render_details_errors(error) if error

    result = Services::UserLists::UpdateList.call(list: list, attrs: attrs)
    return render_details_errors(result.errors.to_sentence) unless result.success?

    mark_user_state_changed
    streams = [
      turbo_stream.replace("list-details", UserLists::Edit::DetailsFormComponent.new(user_list: list)),
      # A rename must reach the heading and the delete confirm copy, which sit outside #list-details.
      turbo_stream.update("list-name-heading", ERB::Util.html_escape(list.name)),
      turbo_stream.append("toast-region", Toast::MessageComponent.new(message: "Saved"))
    ]
    streams << turbo_stream.replace("delete-list-form", partial: "my_lists/delete_form", locals: {list: list}) unless list.default?
    render turbo_stream: streams
  end

  # DELETE /my/lists/:id
  # Deletes a custom list and returns to the dashboard (the navigation is
  # intended). A default list is refused with an error toast.
  def destroy
    list = find_owned_list
    result = Services::UserLists::DeleteList.call(list: list)
    return render_stream_error(result.errors.to_sentence, :unprocessable_entity) unless result.success?

    mark_user_state_changed
    # The dashboard turns this into a toast (my_lists/index.html.erb); no
    # public layout renders flash.
    flash[:notice] = "Deleted “#{list.name}”"
    redirect_to my_lists_path, status: :see_other
  end

  private

  def stream_action?
    STREAM_ACTIONS.include?(action_name.to_sym)
  end

  def require_signed_in_as_stream!
    return if current_user
    render_stream_error(
      (action_name == "create") ? "Sign in again to create a list" : "Sign in again to continue",
      :unauthorized
    )
  end

  def render_new_list_errors(errors)
    render_stream_error(errors.to_sentence, :unprocessable_entity)
  end

  # create answers into the dialog's error line; the Edit page's writes answer
  # with an error toast. Messages are escaped: they may echo user text.
  def render_stream_error(message, status)
    if action_name == "create"
      render turbo_stream: turbo_stream.update("new-list-errors", ERB::Util.html_escape(message)), status: status
    else
      toast = Toast::MessageComponent.new(message: message, type: :error)
      render turbo_stream: turbo_stream.append("toast-region", toast), status: status
    end
  end

  def render_details_errors(message)
    render turbo_stream: turbo_stream.update("list-details-errors", ERB::Util.html_escape(message)),
      status: :unprocessable_entity
  end

  def stream_forbidden(exception)
    return user_not_authorized unless stream_action?
    return render(turbo_stream: [], status: :forbidden) if action_name == "create"
    render_stream_error("You can't change that list", :forbidden)
  end

  def stream_not_found(exception)
    return render_not_found unless stream_action?
    return render(turbo_stream: [], status: :not_found) if action_name == "create"
    render_stream_error("That list no longer exists. Reload the page", :not_found)
  end

  def stream_invalid_token(exception)
    raise exception unless stream_action?
    render_stream_error("Your session expired. Reload the page and try again", :unprocessable_entity)
  end

  # The signed-in owner's list for this domain, or RecordNotFound (404).
  def find_owned_list
    types = UserList.subclasses_for(Current.domain).map(&:name)
    list = current_user.user_lists.where(type: types).find(params[:id])
    authorize list, :update?, policy_class: UserListPolicy
    list
  end

  # Normalised attrs for UpdateList (which trusts its caller), or an error
  # message when the name or description is unacceptable.
  def update_attrs(list)
    raw = params.fetch(:user_list, {}).permit(:name, :description, :public)
    attrs = {}
    # A built-in list's name field is locked; an unchanged name is not a rename.
    if raw.key?(:name) && !(list.default? && raw[:name] == list.name)
      name = Services::UserLists::ListRules.normalize_name(raw[:name])
      return [nil, "Name must be 1 to #{Services::UserLists::ListRules::NAME_MAX} characters"] if name.nil?
      attrs[:name] = name
    end
    if raw.key?(:description)
      description = Services::UserLists::ListRules.normalize_description(raw[:description])
      return [nil, "Description must be at most #{Services::UserLists::ListRules::DESCRIPTION_MAX} characters"] if description == :invalid
      attrs[:description] = description
    end
    attrs[:public] = ActiveModel::Type::Boolean.new.cast(raw[:public]) || false if raw.key?(:public)
    [attrs, nil]
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
