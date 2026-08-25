# frozen_string_literal: true

module Books
  class AuthorPolicy < ApplicationPolicy
    def domain
      "books"
    end

    # execute_action is a shared admin endpoint: write access is the floor to
    # reach it at all. The controller additionally requires destroy? for any
    # action that declares itself destructive (currently only MergeAuthor), so
    # a domain-scoped editor (can_write? but not can_delete?) still cannot
    # merge, even though this policy method returns true for them.
    def execute_action?
      global_role? || domain_role&.can_write?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
