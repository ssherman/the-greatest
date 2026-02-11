# frozen_string_literal: true

module Games
  class PlatformPolicy < ApplicationPolicy
    def domain
      "games"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "games"
      end
    end
  end
end
