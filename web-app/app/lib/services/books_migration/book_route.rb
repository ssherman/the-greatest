module Services
  module BooksMigration
    # Where a legacy user-data row's book lands in a sync run (spec §6): the book
    # itself, its merge survivor, :deleted (the row is dropped and counted), or
    # :waiting, a legacy book above the books watermark that this run has not
    # copied yet because of the 24h delay (skipped and counted; a later run picks
    # the row up). :missing is a book that is none of these: removed here without
    # callbacks (delete_all, raw SQL). The caller decides whether that fails the run.
    class BookRoute
      def initialize(scope, book_ids_here: ::Books::Book.pluck(:id).to_set)
        @redirects = scope.redirects
        @watermark = scope.books_watermark
        @here = book_ids_here
      end

      def call(book_id)
        resolved = @redirects.resolve("Books::Book", book_id)
        return :deleted if resolved == :deleted
        return resolved if @here.include?(resolved)
        return :waiting if resolved == book_id && book_id > @watermark

        :missing
      end

      # Call inside the transaction that writes rows pointing at +book_ids+.
      # Share-locks those books, so a merge or delete (both take the row FOR
      # UPDATE) waits until the write commits, and then moves or removes what was
      # written. Returns true when every book is still here. When one has gone since
      # this route was built (a merge or delete that committed mid-run), it reloads
      # the redirects and the books here and returns false: the caller re-plans its
      # batch, and the gone book now routes to its survivor or :deleted. Without
      # this, a row would land on a book that no longer exists.
      def lock(book_ids)
        ids = book_ids.uniq.sort
        return true if ::Books::Book.where(id: ids).order(:id).lock("FOR SHARE").pluck(:id).size == ids.size

        @redirects = Redirects.load
        @here = ::Books::Book.pluck(:id).to_set
        false
      end
    end
  end
end
