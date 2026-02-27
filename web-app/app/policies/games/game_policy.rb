# frozen_string_literal: true

module Games
  class GamePolicy < ApplicationPolicy
    def domain
      "games"
    end

    def import?
      manage?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "games"
      end
    end
  end
end
