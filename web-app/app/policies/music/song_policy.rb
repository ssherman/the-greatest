# frozen_string_literal: true

module Music
  class SongPolicy < ApplicationPolicy
    def domain
      "music"
    end

    # Allow bulk actions for moderators and above
    def bulk_action?
      global_role? || domain_role&.can_delete?
    end

    # Allow execute_action (custom admin actions) for editors and above
    def execute_action?
      global_role? || domain_role&.can_write?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "music"
      end
    end
  end
end
