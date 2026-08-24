# frozen_string_literal: true

module Music
  class AlbumPolicy < ApplicationPolicy
    def domain
      "music"
    end

    # Allow import action for domain admins
    def import?
      manage?
    end

    # Allow bulk actions for moderators and above
    def bulk_action?
      global_role? || domain_role&.can_delete?
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
        "music"
      end
    end
  end
end
