# frozen_string_literal: true

module Services
  module BooksMigration
    # Relocates any existing new-app `users`/`user_lists` rows out of the reserved
    # low ID range and bumps their sequences above the ceiling, so the future
    # books import can preserve its original IDs without collision.
    #
    # The relocation is a pure additive bijection: every reserved-range id (and
    # every FK referencing it) is shifted by that table's reserved ceiling. This
    # makes the operation trivially collision-free and idempotent — the
    # `< ceiling` guard means a second run skips rows that were already relocated.
    #
    # FK constraints are non-deferrable (ON UPDATE NO ACTION), so a plain parent
    # UPDATE would violate them mid-statement. We drop the involved FKs, shift the
    # ids, then re-add the FKs; re-adding validates every row, which is also our
    # "no orphaned dependents before commit" integrity check.
    #
    # Safe to run multiple times. Wraps everything in a single transaction.
    class IdRangeReservationService
      def self.call
        new.call
      end

      def call
        ActiveRecord::Base.transaction do
          drop_foreign_keys
          relocate_rows
          add_foreign_keys
          bump_sequences
        end
        success({ceilings: RESERVED_CEILINGS})
      rescue => e
        failure(e.message)
      end

      private

      def connection
        ActiveRecord::Base.connection
      end

      # Shift reserved-table PKs, then every FK column that references them, by
      # the referenced table's reserved ceiling. A parent and the FKs pointing at
      # it shift by the same amount, so a child's repointed FK lands exactly on
      # its parent's new id. Already-relocated rows (>= ceiling) are skipped,
      # which is what makes a re-run a no-op.
      def relocate_rows
        FOREIGN_KEYS.each_key do |table|
          ceiling = RESERVED_CEILINGS.fetch(table)
          connection.execute(
            "UPDATE #{table} SET id = id + #{ceiling} WHERE id < #{ceiling}"
          )
        end

        each_foreign_key do |child, column, table|
          ceiling = RESERVED_CEILINGS.fetch(table)
          connection.execute(
            "UPDATE #{child} SET #{column} = #{column} + #{ceiling} WHERE #{column} < #{ceiling}"
          )
        end
      end

      def drop_foreign_keys
        each_foreign_key do |child, column, table|
          if connection.foreign_key_exists?(child, table, column: column)
            connection.remove_foreign_key(child, table, column: column)
          end
        end
      end

      # Re-adding a validated FK forces Postgres to verify every child row points
      # at a real parent — the integrity guarantee, done by the database.
      def add_foreign_keys
        each_foreign_key do |child, column, table|
          unless connection.foreign_key_exists?(child, table, column: column)
            connection.add_foreign_key(child, table, column: column)
          end
        end
      end

      # Move each sequence forward to at least the ceiling (never backward, and
      # never to a value <= the current MAX(id)). Idempotent: skipped once the
      # sequence already sits at/above the target.
      def bump_sequences
        FOREIGN_KEYS.each_key do |table|
          ceiling = RESERVED_CEILINGS.fetch(table)
          seq = connection.select_value(
            "SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')"
          )
          next if seq.blank?

          max_id = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{table}").to_i
          target = [ceiling, max_id + 1].max
          last_value = connection.select_value("SELECT last_value FROM #{seq}").to_i

          connection.execute("ALTER SEQUENCE #{seq} RESTART WITH #{target}") if last_value < target
        end
      end

      def each_foreign_key
        FOREIGN_KEYS.each do |table, fks|
          fks.each { |child, column| yield child, column, table }
        end
      end

      def success(data)
        {success: true, data: data}
      end

      def failure(error)
        {success: false, error: error}
      end
    end
  end
end
