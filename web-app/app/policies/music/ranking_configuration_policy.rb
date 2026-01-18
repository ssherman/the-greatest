# frozen_string_literal: true

module Music
  class RankingConfigurationPolicy < ApplicationPolicy
    def domain
      "music"
    end

    # Ranking configurations are system-level
    # Global admin/editor can manage, domain users need admin level
    def create?
      global_role? || domain_role&.can_manage?
    end

    def new?
      create?
    end

    def update?
      global_role? || domain_role&.can_manage?
    end

    def edit?
      update?
    end

    def destroy?
      global_role? || domain_role&.can_manage?
    end

    # Execute actions on ranking configs require manage permission
    def execute_action?
      global_role? || domain_role&.can_manage?
    end

    def index_action?
      global_role? || domain_role&.can_manage?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "music"
      end
    end
  end
end
