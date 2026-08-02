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
        return @existing if missing_pairs(@existing).empty?

        # one_default_per_type_per_user has no backing DB index, so it cannot stop
        # two concurrent first-visit requests from each seeing no row and both
        # inserting. Serialize on the owning user and re-derive inside the lock.
        # Only the backfill path pays for this: once the set is complete the guard
        # above returns before any lock is taken.
        fresh = nil
        created = []
        @user.with_lock do
          fresh = ::UserList.where(user_id: @user.id, type: subclass_names).to_a
          created = missing_pairs(fresh).filter_map { |klass, list_type| create(klass, list_type) }
        end

        # Return the post-lock read, not the caller's array: if `existing` was
        # loaded before a concurrent request committed, it is already stale.
        fresh + created
      end

      private

      def subclass_names
        ::UserList.subclasses_for(@domain).map(&:name)
      end

      def missing_pairs(existing)
        present = existing.map { |list| [list.class.name, list.list_type.to_s] }
        ::UserList.subclasses_for(@domain).flat_map do |klass|
          klass.default_list_types.filter_map do |list_type|
            [klass, list_type] unless present.include?([klass.name, list_type.to_s])
          end
        end
      end

      # Belt-and-braces inside the lock: if a row somehow exists anyway, reuse it
      # rather than 500ing the page.
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
