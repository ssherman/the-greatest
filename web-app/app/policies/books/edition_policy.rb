# frozen_string_literal: true

module Books
  class EditionPolicy < ApplicationPolicy
    def domain
      "books"
    end

    def set_default?
      update?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
