# frozen_string_literal: true

# UserList authorization for end-user actions.
# Domain-role logic does not apply — these are personal lists.
# update? is owner-only; destroy? is the owner or a global admin (admins can delete anything). Editors get neither.
# STI subclasses must authorize with `policy_class: UserListPolicy` so Pundit
# doesn't resolve to e.g. Music::Albums::UserListPolicy (which doesn't exist).
class UserListPolicy < ApplicationPolicy
  def create?
    user.present?
  end

  # Owners always; everyone else only when the list is public (02d direct-link
  # viewing). Scope stays owner-only — it models "my lists", not "lists I may view".
  def show?
    owner? || record.public?
  end

  def update?
    owner?
  end

  def destroy?
    owner? || global_admin?
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
