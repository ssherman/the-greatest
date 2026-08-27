class UserListItemsController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  before_action :prevent_caching
  before_action :require_signed_in!
  before_action :load_user_list, only: [:create, :destroy]

  # POST /user_lists/:user_list_id/items
  def create
    listable = @user_list.class.listable_class.find(item_attrs[:listable_id])
    candidate = @user_list.user_list_items.new(listable: listable)
    authorize candidate, policy_class: UserListItemPolicy
    result = Services::UserLists::AddItem.call(user_list: @user_list, listable: listable)
    return render_mutation_failure(result) unless result.success?

    invalidate_books_goals(result)
    render json: {
      user_list_item: serialize_item(result.data[:item]),
      removed_user_list_items: result.data[:removed_items].map { |item| serialize_item(item) },
      message: mutation_message(result)
    }, status: :created
  rescue ActiveRecord::RecordNotUnique
    render_conflict("Item already in list")
  end

  # DELETE /user_lists/:user_list_id/items/:id
  def destroy
    item = @user_list.user_list_items.find(params[:id])
    authorize item, policy_class: UserListItemPolicy
    result = Services::UserLists::RemoveItem.call(item: item)
    return render_mutation_failure(result) unless result.success?

    invalidate_books_goals(result)
    render json: {
      ok: true,
      removed_user_list_item: serialize_item(result.data[:item]),
      message: mutation_message(result)
    }
  end

  # PATCH /user_list_items/:id/completion
  def update_completion
    item = current_user.user_list_items.find(params[:id])
    authorize item, :update_completion?, policy_class: UserListItemPolicy
    result = Services::UserLists::UpdateCompletion.call(item: item, completed_on: completion_attrs[:completed_on])
    unless result.success?
      redirect_to my_list_path(item.user_list), alert: result.errors.to_sentence, status: :see_other
      return
    end

    invalidate_books_goals(result)
    redirect_to my_list_path(item.user_list), notice: completion_message(result), status: :see_other
  end

  private

  # Filtering through current_user's lists turns non-owners into 404s before any
  # authorization check, hiding existence per the spec.
  def load_user_list
    @user_list = current_user.user_lists.find(params[:user_list_id])
  end

  def item_attrs
    @item_attrs ||= params.require(:user_list_item).permit(:listable_id)
  end

  def completion_attrs
    @completion_attrs ||= params.require(:user_list_item).permit(:completed_on)
  end

  def render_mutation_failure(result)
    return render_conflict("Item already in list") if result.errors == ["Item already in list"]

    body = error_body(:validation_failed, result.errors.first || "Validation failed")
    body[:error][:details] = {base: result.errors}
    render json: body, status: :unprocessable_entity
  end

  def mutation_message(result)
    item = result.data[:item]
    return "Removed from #{item.user_list.name}" if item.destroyed?

    if result.data[:transitioned]
      "Moved to #{item.user_list.name} and marked completed today"
    elsif item.user_list.completed_on_enabled? && item.completed_on.nil?
      "Added to #{item.user_list.name}. Mark it completed to make it count toward your reading goals."
    else
      "Added to #{item.user_list.name}"
    end
  end

  def completion_message(result)
    result.data[:new_completed_on] ? "Completion date updated" : "Completion date cleared"
  end

  # Task 5 supplies the invalidator and replaces this staged no-op with its call.
  def invalidate_books_goals(_result)
    return nil unless defined?(Services::Books::ReadingGoals::CompletionChangeInvalidator)

    nil
  end

  def serialize_item(item)
    {
      id: item.id,
      user_list_id: item.user_list_id,
      listable_type: item.listable_type,
      listable_id: item.listable_id,
      position: item.position,
      completed_on: item.completed_on&.iso8601
    }
  end
end
