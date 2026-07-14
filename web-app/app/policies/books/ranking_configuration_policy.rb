# frozen_string_literal: true

module Books
  class RankingConfigurationPolicy < ApplicationPolicy
    def domain
      "books"
    end

    def create?
      manage?
    end

    def new?
      create?
    end

    def update?
      manage?
    end

    def edit?
      update?
    end

    def destroy?
      manage?
    end

    def execute_action?
      global_admin? || global_editor? || domain_role&.can_write?
    end

    def index_action?
      global_admin? || global_editor? || domain_role&.can_write?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
