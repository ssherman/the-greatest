# frozen_string_literal: true

module Games
  class GamePolicy < ApplicationPolicy
    def domain
      "games"
    end

    def import?
      manage?
    end

    # Gated on can_delete?, not can_write?: the only action routed through
    # execute_action is a merge, which destroys the source record.
    def execute_action?
      global_role? || domain_role&.can_delete?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "games"
      end
    end
  end
end
