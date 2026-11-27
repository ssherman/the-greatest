# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Records, on each replay row that lacks it, the book legacy put the row on (legacy_book_id). The survey reads
      # it (LegacyBookMap) to know which import-made book a row belongs to, and DecideRow reads it to tell a move or a
      # keep from an add: a row with none is decided "add", which leaves legacy's entry on the reader's shelf beside
      # the right one.
      #
      # The first pass inherited the column from the old replay's resolve step (GoodreadsReplay::CompareEdition,
      # 2026-10-14). Imports loaded since never get it, and that step's lookup (LegacyChoice) can no longer find
      # every book on its own: it reads our identifiers, and the sync stopped copying the Goodreads ids legacy's
      # importer stamps onto books we already have (docs/features/books-legacy-sync.md, "Identifiers"). So this reads
      # legacy's own book_identifiers as well. The rule is LegacyChoice's: among the books holding the row's Goodreads
      # id, the lowest-id one on the reader's lists here. A legacy book removed here since is followed the way the
      # sync routes legacy's list items (Redirects), because that is where the reader's entry sits now: including a
      # deleted mixed book's redirect, which MergedBook deliberately does not follow.
      #
      # Only rows nothing has decided yet: no replay finding (CompareEdition left legacy_book_id empty on purpose for
      # its no_legacy_choice rows) and no applied reimport_row verdict (an applied row has already changed the lists).
      # Writes only legacy_book_id, and only where it is empty. A row nothing traces stays empty and is decided "add",
      # which is right: legacy never put it on the reader's lists.
      class LinkLegacyBooks
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        TYPE = "books_work_goodreads_id"
        LEGACY_GOODREADS_TYPE = 5 # BooksMigration::BookIdentifierMigrator::TYPE_MAP

        # {goodreads book id string => [legacy book ids]} from legacy's book_identifiers. Its values can be slugs
        # ("12345-title"), so the id is the leading digits.
        LEGACY_HOLDERS = lambda do |goodreads_ids|
          ::LegacyBooks::BookIdentifier.where(identifier_type: LEGACY_GOODREADS_TYPE)
            .where("substring(identifier from '^[0-9]+') IN (?)", goodreads_ids)
            .pluck(:identifier, :book_id)
            .group_by { |value, _| value[/\A\d+/] }
            .transform_values { |pairs| pairs.map(&:last) }
        end

        def self.call(user_ids:, legacy_holders: LEGACY_HOLDERS)
          new(user_ids, legacy_holders).call
        end

        # Readers with at least one unlinked row in a complete replay import.
        def self.user_ids_to_link
          unlinked_rows.distinct.pluck("books_goodreads_imports.user_id").sort
        end

        def self.unlinked_rows
          applied = ::Books::RepairVerdict.reimport_row.where.not(applied_at: nil)
            .where("books_repair_verdicts.subject_key = 'reimport:row:' || books_goodreads_import_rows.import_id || ':' || " \
              "books_goodreads_import_rows.row_number")
          ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
            .where(legacy_book_id: nil, replay_finding: nil).where.not(goodreads_edition_id: nil)
            .where.not(applied.arel.exists)
        end

        def initialize(user_ids, legacy_holders)
          @user_ids = user_ids
          @legacy_holders = legacy_holders
          @redirects = ::Services::BooksMigration::Redirects.load
        end

        def call
          rows = self.class.unlinked_rows.where(books_goodreads_imports: {user_id: @user_ids})
            .includes(:import, :goodreads_edition).to_a
          goodreads_ids = rows.map { |row| row.goodreads_edition.goodreads_book_id.to_s }.uniq
          holders = holders_for(goodreads_ids)
          linked = unlinked = 0
          rows.group_by { |row| row.import.user_id }.each do |user_id, user_rows|
            on_lists = book_ids_on_lists(user_id)
            user_rows.each do |row|
              book_id = holders.fetch(row.goodreads_edition.goodreads_book_id.to_s, []).select { |id| on_lists.include?(id) }.min
              if book_id
                row.update_columns(legacy_book_id: book_id, updated_at: Time.current)
                linked += 1
              else
                unlinked += 1
              end
            end
          end
          Result.new(success?: true, data: {linked: linked, unlinked: unlinked}, errors: [])
        end

        private

        # {goodreads book id string => [book ids here]}: our holders (plain and slug-form values) plus legacy's,
        # each legacy id routed the way the sync routes it (a deleted book drops out).
        def holders_for(goodreads_ids)
          return {} if goodreads_ids.empty?

          ours = ::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE)
            .where("substring(value from '^[0-9]+') IN (?)", goodreads_ids).pluck(:value, :identifiable_id)
            .group_by { |value, _| value[/\A\d+/] }.transform_values { |pairs| pairs.map(&:last) }
          theirs = @legacy_holders.call(goodreads_ids)
          goodreads_ids.to_h do |id|
            legacy_now = Array(theirs[id]).filter_map do |legacy_id|
              routed = @redirects.resolve("Books::Book", legacy_id)
              routed if routed.is_a?(Integer)
            end
            [id, (Array(ours[id]) + legacy_now).uniq]
          end
        end

        def book_ids_on_lists(user_id)
          ::UserListItem.joins(:user_list).where(user_lists: {user_id: user_id}, listable_type: "Books::Book")
            .pluck(:listable_id).to_set
        end
      end
    end
  end
end
