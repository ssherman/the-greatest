# Row writes on the owner's Edit page: move, remove and undo. Every action is
# Turbo-only and answers with a stream that morphs #edit-list-rows to the
# truth plus (usually) a toast, success or failure alike, so the page never
# navigates, reloads a frame or loses its scroll position. Failures are streams
# too: an HTML error body on a non-2xx status would replace the whole page.
class MyListItemsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include EditPageRows

  UNDO_TTL = 8000

  before_action :prevent_caching
  before_action :require_signed_in_as_stream!
  before_action :load_list

  rescue_from Pundit::NotAuthorizedError, with: :stream_forbidden
  rescue_from ActiveRecord::RecordNotFound, with: :stream_not_found
  rescue_from ActionController::InvalidAuthenticityToken, with: :stream_invalid_token

  # PATCH /my/lists/:id/items/:item_id/position
  def move
    item = @list.user_list_items.find(params[:item_id])
    position = parse_integer(item_params&.dig(:position))
    return render_rows(toast("Enter a position between 1 and #{@list.user_list_items.count}", :error), :unprocessable_entity) if position.nil?

    result = Services::UserLists::UpdateItem.call(item: item, position: position)
    return render_failure(result.errors, :unprocessable_entity) unless result.success?

    message = "Moved to ##{position}" if page_for(position) != requested_page
    render_rows(message && toast(message))
  end

  # DELETE /my/lists/:id/items/:item_id
  def destroy
    item = @list.user_list_items.find(params[:item_id])
    listable = item.listable
    undo = {
      listable_id: listable.id,
      position: item.position,
      completed_on: item.completed_on&.iso8601.to_s,
      added_at: item.created_at.iso8601(6),
      page: requested_page
    }

    result = Services::UserLists::RemoveItems.call(user_list: @list, listables: [listable])
    return render_failure(result.errors, :unprocessable_entity) unless result.success?

    action = {label: "Undo", url: restore_my_list_item_path(@list), method: :post, params: undo}
    render_rows(toast("Removed #{title_of(listable)}", action: action, ttl: UNDO_TTL))
  end

  # POST /my/lists/:id/items/restore
  def restore
    listable_id = parse_integer(params[:listable_id])
    position = parse_integer(params[:position])
    completed_on = parse_date(params[:completed_on])
    listable = @list.class.listable_class.find_by(id: listable_id) if listable_id
    return render_failure(["Could not undo that removal"], :unprocessable_entity) if listable.nil? || position.nil? || completed_on == :invalid

    result = Services::UserLists::RestoreItem.call(
      user_list: @list, listable: listable, position: position,
      completed_on: completed_on, added_at: params[:added_at].presence
    )
    return render_failure(result.errors, :unprocessable_entity) unless result.success?

    render_rows(toast("Restored #{title_of(listable)}"))
  end

  private

  def require_signed_in_as_stream!
    return if current_user

    render_failure(["Sign in again to edit this list"], :unauthorized)
  end

  # The signed-in owner's list for this domain; anything else is a 404.
  def load_list
    types = UserList.subclasses_for(Current.domain).map(&:name)
    @list = current_user.user_lists.where(type: types).find(params[:id])
    authorize @list, :update?, policy_class: UserListPolicy
  end

  def item_params
    raw = params[:user_list_item]
    raw if raw.is_a?(ActionController::Parameters)
  end

  def parse_integer(value)
    Integer(value.to_s, exception: false)
  end

  # nil for blank, :invalid for a value that is not an ISO date.
  def parse_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    :invalid
  end

  def page_for(position)
    ((position - 1) / EDIT_PAGE_LIMIT) + 1
  end

  def title_of(listable)
    listable.try(:title) || listable.try(:name)
  end

  def toast(message, type = :success, **options)
    turbo_stream.append("toast-region", Toast::MessageComponent.new(message: message, type: type, **options))
  end

  # The rows morph to the truth in every answer; the toast is optional.
  def render_rows(toast_stream = nil, status = :ok)
    streams = []
    if @list
      pagy, items = load_edit_rows(@list, page: requested_page)
      streams << turbo_stream.replace(
        "edit-list-rows",
        UserLists::Edit::RowsComponent.new(user_list: @list, items: items, pagy: pagy),
        method: :morph
      )
    end
    streams << toast_stream if toast_stream
    render turbo_stream: streams, status: status
  end

  def render_failure(errors, status)
    render_rows(toast(Array(errors).to_sentence, :error), status)
  end

  def stream_forbidden(exception)
    render_failure(["You can't change that list"], :forbidden)
  end

  def stream_not_found(exception)
    render_failure(["That item is no longer in this list"], :not_found)
  end

  # The token check runs before the domain is resolved and before load_list, so
  # neither may have happened yet; the rows still morph to the truth when the
  # list can be found.
  def stream_invalid_token(exception)
    set_current_domain if Current.domain.nil?
    load_list if current_user && @list.nil?
    render_failure(["Your session expired. Reload the page and try again"], :unprocessable_entity)
  rescue ActiveRecord::RecordNotFound, Pundit::NotAuthorizedError
    @list = nil
    render_failure(["Your session expired. Reload the page and try again"], :unprocessable_entity)
  end
end
