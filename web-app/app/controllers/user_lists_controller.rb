class UserListsController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  ALLOWED_TYPES = %w[
    Music::Albums::UserList
    Music::Songs::UserList
    Games::UserList
    Movies::UserList
  ].freeze

  before_action :prevent_caching
  before_action :require_signed_in!

  # POST /user_lists
  # Creates a custom UserList (server forces list_type = :custom). If listable_id
  # is supplied, the list and its first item are created in one transaction.
  def create
    klass = resolve_list_class
    return if performed?

    list = klass.new(
      user: current_user,
      name: list_attrs[:name],
      description: list_attrs[:description],
      public: ActiveModel::Type::Boolean.new.cast(list_attrs[:public]) || false,
      list_type: :custom
    )
    # Use the shared UserListPolicy regardless of STI subclass.
    authorize list, :create?, policy_class: UserListPolicy

    item = nil
    ActiveRecord::Base.transaction do
      list.save!
      if list_attrs[:listable_id].present?
        listable = klass.listable_class.find(list_attrs[:listable_id])
        item = list.user_list_items.create!(listable: listable)
      end
    end

    body = {user_list: serialize_list(list)}
    body[:user_list_item] = serialize_item(item) if item
    render json: body, status: :created
  end

  private

  def resolve_list_class
    type = list_attrs[:type].to_s
    unless ALLOWED_TYPES.include?(type)
      render json: {
        error: {
          code: "validation_failed",
          message: "Type is not a valid user list type",
          details: {type: ["is not a valid user list type"]}
        }
      }, status: :unprocessable_entity
      return nil
    end
    type.constantize
  end

  def list_attrs
    @list_attrs ||= params.require(:user_list).permit(:type, :name, :description, :public, :listable_id)
  end

  def serialize_list(list)
    {
      id: list.id,
      type: list.class.name,
      list_type: list.list_type,
      name: list.name,
      description: list.description,
      public: list.public,
      default: list.default?,
      icon: list.class.list_type_icons[list.list_type.to_sym]
    }
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
