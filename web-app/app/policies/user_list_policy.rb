# frozen_string_literal: true

# UserList authorization for end-user (owner-only) actions.
# Domain-role logic does not apply — these are personal lists.
# show?/update?/destroy?/scope are intentionally left unimplemented in 02a; 02c adds them.
class UserListPolicy < ApplicationPolicy
  def create?
    user.present?
  end
end
