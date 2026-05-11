class UserListItemsController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  before_action :prevent_caching
  before_action :require_signed_in!
  before_action :load_user_list

  # POST /user_lists/:user_list_id/items
  def create
    listable = @user_list.class.listable_class.find(item_attrs[:listable_id])
    item = @user_list.user_list_items.new(listable: listable)
    authorize item, policy_class: UserListItemPolicy

    if item.save
      render json: {user_list_item: serialize_item(item)}, status: :created
    elsif duplicate_item?(item)
      render_conflict("Item already in list")
    else
      render_validation_failed(item)
    end
  rescue ActiveRecord::RecordNotUnique
    render_conflict("Item already in list")
  end

  # DELETE /user_lists/:user_list_id/items/:id
  def destroy
    item = @user_list.user_list_items.find(params[:id])
    authorize item, policy_class: UserListItemPolicy
    item.destroy!
    render json: {ok: true}
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

  def duplicate_item?(item)
    item.errors.added?(:listable_id, :taken, value: item.listable_id) ||
      item.errors[:listable_id].any? { |m| m.include?("already in this list") }
  end

  def serialize_item(item)
    {
      id: item.id,
      user_list_id: item.user_list_id,
      listable_type: item.listable_type,
      listable_id: item.listable_id,
      position: item.position
    }
  end
end
