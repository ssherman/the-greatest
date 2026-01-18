# frozen_string_literal: true

module Music
  class ListPolicy < ApplicationPolicy
    def domain
      "music"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "music"
      end
    end
  end
end
