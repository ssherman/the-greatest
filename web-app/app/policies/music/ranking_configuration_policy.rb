# frozen_string_literal: true

module Music
  class RankingConfigurationPolicy < ApplicationPolicy
    def domain
      "music"
    end

    # Ranking configurations are system-level resources
    # Only global admin or domain admin can modify them
    # Global editor does NOT have manage access (only read/write, not manage)
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

    # Execute actions on ranking configs require manage permission
    def execute_action?
      manage?
    end

    def index_action?
      manage?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "music"
      end
    end
  end
end
