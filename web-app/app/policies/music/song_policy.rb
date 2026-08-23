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

    # Gated on can_delete?, not can_write?: execute_action routes merges, which
    # destroy the source record. A domain editor could otherwise delete a record
    # they are not permitted to delete.
    def execute_action?
      global_role? || domain_role&.can_delete?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "music"
      end
    end
  end
end
