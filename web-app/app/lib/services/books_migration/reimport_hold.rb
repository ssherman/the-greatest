module Services
  module BooksMigration
    # The (reader, book) pairs the Goodreads re-import changed, which the weekly legacy sync must leave
    # alone: legacy still holds the old importer's guesses, so syncing those pairs would undo the re-import
    # already applied in production (spec 2026-11-26-books-sync-keeps-reimport, section 1). Built once per
    # sync from the re-import verdicts and read through held?.
    #
    # Each book id is expanded through the merges recorded since (Redirects), so a pair matches both the
    # legacy book id a row names and the book it routes to here. The one redirect NOT followed is the one a
    # deleted mixed book left (spec 5.1): it points at the mixed book's most-read destination, which the
    # re-import did not touch for every reader of the mixed book, so following it would hold pairs nobody
    # changed. The mixed book itself stays held; a legacy row naming it is caught by the legacy id.
    class ReimportHold
      BOOK = "Books::Book"

      # Verdicts that recorded a change: their payload has `moved` or `leftovers_removed`, applied or not, current or
      # superseded (a superseded guess can already carry `moved`)
      # (a change can be recorded before applied_at is).
      CHANGED = "(payload ? 'moved' OR payload ? 'leftovers_removed')"

      def self.none = new(pairs: [], redirects: Redirects.new([]))

      def self.load(redirects:)
        verdicts = ::Books::RepairVerdict.all
        pairs = []
        moves = verdicts.where(kind: [:reimport_row, :reimport_guess]).where(Arel.sql(CHANGED))
          .pluck(Arel.sql("payload->>'user_id'"), Arel.sql("payload->>'from_book_id'"), Arel.sql("payload->>'to_book_id'"))
        moves.each do |user_id, from_id, to_id|
          [from_id, to_id].each { |book_id| pairs << [user_id, book_id] if user_id && book_id }
        end

        mixed_book_ids = Set.new
        verdicts.reimport_mixed.pluck(Arel.sql("payload->>'book_id'"), Arel.sql("payload->'deleted'")).each do |book_id, deleted|
          next unless book_id

          mixed_book_ids << book_id.to_i
          Array(deleted).each { |item| pairs << [item["user_id"], book_id] if item["user_id"] }
        end

        new(pairs: pairs.map { |user_id, book_id| [user_id.to_i, book_id.to_i] }, redirects: redirects, mixed_book_ids: mixed_book_ids)
      end

      # pairs: Enumerable of [user_id, book_id] Integers.
      def initialize(pairs:, redirects:, mixed_book_ids: Set.new)
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

      def held?(user_id, book_id)
        return false unless book_id.is_a?(Integer)

        @held.include?([user_id, book_id])
      end

      def size = @held.size
    end
  end
end
