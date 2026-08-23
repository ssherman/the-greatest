# frozen_string_literal: true

module Games
  class GamePolicy < ApplicationPolicy
    def domain
      "games"
    end

    def import?
      manage?
    end

    # execute_action is a shared endpoint: it carries non-destructive actions
    # (AI descriptions, ranking refresh) as well as merges. Write access is the
    # floor; the controller additionally requires destroy? for actions that
    # declare themselves destructive.
    def execute_action?
      global_role? || domain_role&.can_write?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "games"
      end
    end
  end
end
