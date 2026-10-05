# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.6: clear junk goes provisional, hidden from
      # every public surface until an admin decides. Two kinds of book qualify:
      # - An authorless book: legacy root cause 5, a bare book no
      #   author-required search can find. On a curated list it is only
      #   proposed, so no list page loses a book unasked. Curated list pages are
      #   not filtered by provisional.
      # - A book every holder has been relinked away from (approved relinks),
      #   with no curated-list item and no other user's list item or review.
      # Records findings only; Apply::MarkProvisional sets the flag.
      class FindJunk
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call
          new.call
        end

        def call
          Result.new(success?: true, data: {authorless: authorless, orphaned: orphaned}, errors: [])
        end

        private

        def authorless
          count = 0
          ::Books::Book.where(provisional: false).where.not(id: ::Books::BookAuthor.select(:book_id)).find_each do |book|
            lists = curated_list_ids(book)
            RecordVerdict.call(
              kind: :mark_provisional, subject_key: "book:#{book.id}",
              payload: {book_id: book.id, reason: "authorless", curated_list_ids: lists},
              decided_by: :rule, confidence: :certain, auto: lists.empty?,
              reason: lists.empty? ? "authorless, on no curated list" : "authorless, but on curated lists #{lists.join(", ")}"
            )
            count += 1
          end
          count
        end

        def orphaned
          count = 0
          ::Books::RepairVerdict.relink.approved.to_a.group_by { |verdict| verdict.payload["from_book_id"] }.each do |book_id, verdicts|
            book = ::Books::Book.find_by(id: book_id, provisional: false)
            next unless book

            moved = verdicts.map { |verdict| verdict.payload["user_id"] }.uniq.sort
            next if curated_list_ids(book).any?
            # A relinked user whose other row still names the book keeps it (Apply::Relink copies).
            next if verdicts.any? do |verdict|
              Apply::Relink.supported_elsewhere?(user_id: verdict.payload["user_id"], from_book: book,
                goodreads_book_id: verdict.payload["goodreads_book_id"])
            end
            next if ::UserListItem.joins(:user_list).where(listable: book).where.not(user_lists: {user_id: moved}).exists?
            next if ::Review.where(reviewable: book).where.not(user_id: moved).exists?

            RecordVerdict.call(
              kind: :mark_provisional, subject_key: "book:#{book.id}",
              payload: {book_id: book.id, reason: "no support after relinks", relinked_user_ids: moved},
              decided_by: :rule, confidence: :certain, auto: true,
              reason: "every user who had it is relinked away, and no curated list or other user has it"
            )
            count += 1
          end
          count
        end

        def curated_list_ids(book)
          ::ListItem.joins(:list).where(listable: book, lists: {auto_generated_kind: nil}).distinct.order(:list_id).pluck(:list_id)
        end
      end
    end
  end
end
