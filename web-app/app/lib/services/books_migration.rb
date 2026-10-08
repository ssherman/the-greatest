# frozen_string_literal: true

module Services
  # Reserves low primary-key ID ranges for the Greatest Books migration. Books rows
  # are imported preserving their original auto-increment IDs in `[1, ceiling)`;
  # every new-app row lives at `>= ceiling`. See
  # docs/specs/completed/books-migration-01-id-range-reservation.md (users,
  # user_lists, lists) and docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md
  # (the four catalog tables).
  module BooksMigration
    # Per-table reserved ceilings: books rows keep their original IDs below the
    # ceiling; new-app rows are minted at `>= ceiling`. Sized with headroom over
    # the legacy books site's MAX(id) -- re-confirm it is still well under each
    # ceiling before the cutover, and raise a ceiling if needed (cost is zero on a
    # bigint PK).
    #
    # users/user_lists/lists (as of 2026-06/07) were reserved by relocating
    # new-app rows up (IdRangeReservationService). The other tables (legacy max on
    # 2026-10-08: books 175,879; authors 80,329; reviews 153,446; saved searches
    # 6,070; changesets 771) held only legacy rows below legacy's max, so they are
    # reserved by moving the sequence alone -- see SEQUENCE_FLOOR_TABLES.
    RESERVED_CEILINGS = {
      "users" => 150_000,
      "user_lists" => 1_000_000,
      "lists" => 10_000,
      "books_books" => 250_000,
      "books_authors" => 120_000,
      "reviews" => 250_000,
      "saved_searches" => 20_000,
      "corrections" => 10_000
    }.freeze

    # Reserved by sequence only. Never pass these to IdRangeReservationService:
    # its relocation shifts every row below the ceiling, which here means the
    # preserved legacy ids themselves.
    SEQUENCE_FLOOR_TABLES = %w[books_books books_authors reviews saved_searches corrections].freeze

    # Reserved table => the FK columns that must be remapped when one of its rows
    # is relocated out of the reserved range. Verified against db/schema.rb
    # (version 2026_07_03_190903). Any FK added before this migration ships must
    # be added here.
    #
    #   "users"      <- ai_chats.user_id, domain_roles.user_id,
    #                   external_links.submitted_by_id, lists.submitted_by_id,
    #                   penalties.user_id, ranking_configurations.user_id,
    #                   user_lists.user_id
    #   "user_lists" <- user_list_items.user_list_id
    #   "lists"      <- list_items.list_id, list_penalties.list_id,
    #                   ranked_lists.list_id, ranking_configurations.primary_mapped_list_id,
    #                   ranking_configurations.secondary_mapped_list_id
    FOREIGN_KEYS = {
      "users" => [
        ["ai_chats", "user_id"],
        ["domain_roles", "user_id"],
        ["external_links", "submitted_by_id"],
        ["lists", "submitted_by_id"],
        ["penalties", "user_id"],
        ["ranking_configurations", "user_id"],
        ["user_lists", "user_id"]
      ],
      "user_lists" => [
        ["user_list_items", "user_list_id"]
      ],
      "lists" => [
        ["list_items", "list_id"],
        ["list_penalties", "list_id"],
        ["ranked_lists", "list_id"],
        ["ranking_configurations", "primary_mapped_list_id"],
        ["ranking_configurations", "secondary_mapped_list_id"]
      ]
    }.freeze

    # Polymorphic references have no DB FK. Rails stores the STI *base* class
    # name in the `_type` column, so every list's ai_chat is `parent_type = "List"`.
    # Format: [child_table, id_column, type_column, type_value].
    POLYMORPHIC_FOREIGN_KEYS = {
      "lists" => [
        ["ai_chats", "parent_id", "parent_type", "List"]
      ]
    }.freeze

    def self.reserve_sequence_floors!
      SEQUENCE_FLOOR_TABLES.index_with { |table| bump_sequence_to_floor!(table) }
    end

    # Moves the table's id sequence so the next id is at least the ceiling and
    # above every existing row. Never moves it backward. Returns the next id.
    def self.bump_sequence_to_floor!(table, ceiling: RESERVED_CEILINGS.fetch(table))
      connection = ActiveRecord::Base.connection
      sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
      max_id = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i
      last_value, is_called = connection.select_rows("SELECT last_value, is_called FROM #{sequence}").first
      current_next = ActiveModel::Type::Boolean.new.cast(is_called) ? last_value.to_i + 1 : last_value.to_i
      target = [ceiling, max_id + 1].max
      return current_next if current_next >= target

      connection.execute("SELECT setval(#{connection.quote(sequence)}, #{target}, false)")
      target
    end

    # A legacy id at or above the ceiling would land in the range new-app rows
    # are minted from, and from then on "below the ceiling" would no longer mean
    # "came from legacy".
    def self.raise_if_at_ceiling!(table, id)
      ceiling = RESERVED_CEILINGS.fetch(table)
      return if id.to_i < ceiling

      raise "legacy #{table} id #{id} reaches the reserved ceiling #{ceiling}; raise RESERVED_CEILINGS[#{table.inspect}]"
    end

    SUPPRESS_KEY = :books_migration_suppress_search

    # Runs the block with SearchIndexable enqueuing disabled on this thread, so a
    # bulk migration doesn't create a SearchIndexRequest per row. Always restores
    # the flag, even on error.
    def self.without_search_indexing
      previous = Thread.current[SUPPRESS_KEY]
      Thread.current[SUPPRESS_KEY] = true
      yield
    ensure
      Thread.current[SUPPRESS_KEY] = previous
    end

    def self.search_indexing_suppressed?
      Thread.current[SUPPRESS_KEY] == true
    end
  end
end
