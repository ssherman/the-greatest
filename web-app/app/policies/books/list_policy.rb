# frozen_string_literal: true

module Books
  class ListPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
