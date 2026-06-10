# frozen_string_literal: true

# UserList authorization for end-user (owner-only) actions.
# Domain-role logic does not apply — these are personal lists.
# update?/destroy? are added in Phase B (user-lists-02f); public-list viewing is 02d.
# STI subclasses must authorize with `policy_class: UserListPolicy` so Pundit
# doesn't resolve to e.g. Music::Albums::UserListPolicy (which doesn't exist).
class UserListPolicy < ApplicationPolicy
  def create?
    user.present?
  end

  # Phase A is owner-only. Viewing other users' public lists is 02d.
  def show?
    owner?
  end

  def owner?
    record.user_id == user&.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user_id: user&.id)
    end
  end
end
