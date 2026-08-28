# frozen_string_literal: true

module Books
  class BookPolicy < ApplicationPolicy
    def domain
      "books"
    end

    # execute_action is a shared admin endpoint: write access is the floor to
    # reach it at all. The controller additionally requires destroy? for any
    # action that declares itself destructive (currently only MergeBook), so a
    # domain-scoped editor (can_write? but not can_delete?) still cannot merge,
    # even though this policy method returns true for them. Gating this method
    # itself on can_delete? would break non-destructive actions on the shared
    # endpoint -- see departure 3 in the design doc.
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
