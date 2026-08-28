# frozen_string_literal: true

module Books
  class ReadingGoalPolicy < ApplicationPolicy
    def show?
      record.public? || owner? || global_admin?
    end

    def create? = user.present?
    def new? = create?
    def update? = owner? || global_admin?
    def edit? = update?
    def destroy? = update?

    class Scope < ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.admin?
        return scope.none unless user

        scope.where(user: user)
      end
    end

    private

    def owner? = user.present? && record.user_id == user.id
  end
end
