module Services
  module BooksMigration
    # The (reader, book) pairs the Goodreads re-import changed, which the weekly legacy sync must leave
    # alone: legacy still holds the old importer's guesses, so syncing those pairs would undo the re-import
    # already applied in production (spec 2026-11-26-books-sync-keeps-reimport, section 1). Built once per
    # sync from the re-import verdicts and read through held?.
    #
    # Each book id is expanded through the merges recorded since (Redirects), so a pair matches both the
    # legacy book id a row names and the book it routes to here. The redirects NOT followed are the ones a
    # deleted mixed book left (spec 5.1): its own, and the ones of books merged into it earlier, which
    # Apply::Mixed repointed at the same place. They point at the mixed book's most-read destination, which
    # the re-import did not touch for every reader of the mixed book, so following them would hold pairs
    # nobody changed. A mixed book the re-import kept is an ordinary book: a later merge of it is followed.
    #
    # Immutable. A merge that commits while the sync runs changes the redirects; with_redirects gives the
    # hold expanded through the new ones, so the hold and the BookRoute reading them agree.
    class ReimportHold
      BOOK = "Books::Book"

      # Verdicts that recorded a change: their payload has `moved` or `leftovers_removed`. Applied or not (a change
      # can be recorded before applied_at is), current or superseded (a superseded guess can already carry `moved`).
      CHANGED = "(payload ? 'moved' OR payload ? 'leftovers_removed')"

      attr_reader :redirects

      def self.none = new(pairs: [], redirects: Redirects.new([]))

      def self.load(redirects:)
        verdicts = ::Books::RepairVerdict.all
        pairs = []
        moves = verdicts.where(kind: [:reimport_row, :reimport_guess]).where(Arel.sql(CHANGED))
          .pluck(Arel.sql("payload->>'user_id'"), Arel.sql("payload->>'from_book_id'"), Arel.sql("payload->>'to_book_id'"))
        moves.each do |user_id, from_id, to_id|
          [from_id, to_id].each { |book_id| pairs << [user_id, book_id] if user_id && book_id }
        end

        # Apply::Mixed writes redirect_written (false, then true once the redirect is recorded) in the same
        # transaction that deletes the book, and nowhere else, so the key marks a mixed book that was deleted.
        # A kept one has `deleted` items too (its removed leftovers), but no redirect of its own to skip.
        unfollowed = Set.new
        mixed = verdicts.reimport_mixed.pluck(Arel.sql("payload->>'book_id'"), Arel.sql("payload->'deleted'"),
          Arel.sql("payload ? 'redirect_written'"), Arel.sql("payload->'redirected_here'"))
        mixed.each do |book_id, deleted, book_deleted, redirected_here|
          next unless book_id

          readers = Array(deleted).filter_map { |item| item["user_id"] }
          readers.each { |user_id| pairs << [user_id, book_id] }
          next unless book_deleted

          # A legacy row can still name a book merged into the mixed book before it was deleted: hold the reader
          # there too, without following that book's redirect (now the mixed book's destination).
          here = Array(redirected_here)
          unfollowed << book_id.to_i
          unfollowed.merge(here.map(&:to_i))
          here.each { |from_id| readers.each { |user_id| pairs << [user_id, from_id] } }
        end

        new(pairs: pairs.map { |user_id, book_id| [user_id.to_i, book_id.to_i] }, redirects: redirects, mixed_book_ids: unfollowed)
      end

      # pairs: Enumerable of [user_id, book_id] Integers. mixed_book_ids: the books whose redirect is not followed.
      def initialize(pairs:, redirects:, mixed_book_ids: Set.new)
        @pairs = pairs
        @redirects = redirects
        @mixed_book_ids = mixed_book_ids
        @held = Set.new
        pairs.each do |user_id, book_id|
          current = book_id
          seen = Set.new
          while current && seen.add?(current)
            @held << [user_id, current]
            break if mixed_book_ids.include?(current) || !redirects.redirected?(BOOK, current)

            current = redirects.target(BOOK, current)
          end
        end
      end

      # This hold expanded through +redirects+ instead (the same object when they are the ones it has).
      def with_redirects(redirects)
        return self if redirects.equal?(@redirects)

        self.class.new(pairs: @pairs, redirects: redirects, mixed_book_ids: @mixed_book_ids)
      end

      def held?(user_id, book_id)
        return false unless book_id.is_a?(Integer)

        @held.include?([user_id, book_id])
      end

      def size = @held.size
    end
  end
end
