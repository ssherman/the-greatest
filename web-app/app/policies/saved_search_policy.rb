# frozen_string_literal: true

# SavedSearch authorization. These are personal searches, so domain-role logic
# does not apply.
# STI subclasses must authorize with `policy_class: SavedSearchPolicy` so Pundit
# doesn't resolve to e.g. Books::SavedSearchPolicy, which doesn't exist.
class SavedSearchPolicy < ApplicationPolicy
  def index?
    true
  end

  # Public means readable, never writable -- see update?/destroy?.
  def show?
    record.public? || owner?
  end

  def create?
    user.present?
  end

  def new?
    create?
  end

  def update?
    owner?
  end

  def edit?
    update?
  end

  def destroy?
    owner?
  end

  def owner?
    user.present? && record.user_id == user.id
  end

  # The inherited default (ApplicationPolicy::Scope#resolve) treats admin/editor
  # as a global bypass and returns scope.all -- correct for domain-owned content,
  # wrong here because these are personal, sometimes-private searches. An admin
  # calling policy_scope(SavedSearch) must see the same visible set as anyone
  # else: their own plus everyone's public ones, never another user's private one.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.visible_to(user)
    end
  end
end
