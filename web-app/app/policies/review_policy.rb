# frozen_string_literal: true

# Review authorization for end-user actions. Domain-role logic does not apply --
# a review belongs to the person who wrote it.
#
# Mirrors the legacy app: any signed-in user may create; editing and deleting
# require ownership. Reading is public and needs no policy -- increment 3 renders
# reviews on a page served to anonymous visitors.
class ReviewPolicy < ApplicationPolicy
  def create?
    user.present?
  end

  def update?
    owner?
  end

  def destroy?
    owner?
  end

  def owner?
    user.present? && record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?

      scope.where(user_id: user.id)
    end
  end
end
