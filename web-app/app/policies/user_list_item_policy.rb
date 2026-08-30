# frozen_string_literal: true

# UserListItem authorization. Owner of the parent UserList may add/remove items.
class UserListItemPolicy < ApplicationPolicy
  def create?
    owner?
  end

  def destroy?
    owner?
  end

  def update_completion?
    owner?
  end

  private

  def owner?
    user.present? && record.user_list.user_id == user.id
  end
end
