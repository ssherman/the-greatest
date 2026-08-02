# frozen_string_literal: true

module Services
  module UserLists
    # Idempotently creates any of a domain's default UserLists that a user is
    # missing, and returns the merged set.
    #
    # User#create_default_user_lists only fires on signup, so users created
    # before a subclass joined DEFAULT_SUBCLASSES have none of its lists. The
    # legacy books import also left ~145 users short of a default on purpose.
    #
    # Callers pass the lists they already loaded, so the common case (nothing
    # missing) costs zero extra queries and zero writes. That matters: one
    # caller runs on every signed-in page view.
    class EnsureDefaults
      def self.call(user:, domain:, existing:)
        new(user: user, domain: domain, existing: existing).call
      end

      def initialize(user:, domain:, existing:)
        @user = user
        @domain = domain
        @existing = existing
      end

      def call
        missing = missing_pairs
        return @existing if missing.empty?

        @existing + missing.filter_map { |klass, list_type| create(klass, list_type) }
      end

      private

      def missing_pairs
        present = @existing.map { |list| [list.class.name, list.list_type.to_s] }
        ::UserList.subclasses_for(@domain).flat_map do |klass|
          klass.default_list_types.filter_map do |list_type|
            [klass, list_type] unless present.include?([klass.name, list_type.to_s])
          end
        end
      end

      # one_default_per_type_per_user is a model-level validation with no backing
      # DB index, so two concurrent requests can both pass it. Lose the race
      # quietly and re-read rather than 500ing the page.
      def create(klass, list_type)
        klass.find_or_create_by!(user: @user, list_type: list_type) do |list|
          list.name = klass.default_list_name_for(list_type)
        end
      rescue ActiveRecord::RecordInvalid
        klass.find_by(user: @user, list_type: list_type)
      end
    end
  end
end
