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
    record.user_id == user&.id
  end
end
