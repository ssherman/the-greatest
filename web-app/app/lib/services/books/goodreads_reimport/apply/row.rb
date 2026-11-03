# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_row verdict (re-import spec 4.6, 8 calls 1 and 2): what one CSV row of one reader
        # does to the reader's entries. The deadlock retry is the caller's (ApplyVerdicts#call_handler).
        #
        # Every branch looks at what the user has NOW, never at the payload alone: the verdict was decided
        # earlier, and the reader, an admin or a sibling verdict may have changed things since.
        # - keep (and any superseded row): nothing.
        # - add: the row's entries on the destination, by LibraryRules; a list that already holds the book is
        #   left as it is. review: true writes the CSV's rating and review.
        # - move: ALL the user's items on the old book (every list) go to the destination, with Relink's
        #   collision rules. The user's review goes only when review: true.
        # - copy: the row's entries are created on the destination, dated from this row; the old book's items
        #   stay (the mixed-book delete or a later move removes them). review: true carries the user's review
        #   from the old book (moved); with none there, the CSV's is written.
        # A user has one review per book. An existing review on the destination always wins.
        class Row
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?

            payload = verdict.payload
            action = payload["action"]
            return Entries.noop("superseded by #{payload["superseded_by"]}") if payload["superseded_by"].present?
            return Entries.noop("keep") if action == "keep"
            return Entries.noop("unknown action #{action.inspect}") unless %w[add move copy].include?(action)

            user = ::User.find_by(id: payload["user_id"])
            return Entries.noop("user #{payload["user_id"]} no longer exists") unless user

            to = GoodreadsReplay::Apply::MergedBook.call(payload["to_book_id"])
            return Entries.noop("book #{payload["to_book_id"]} no longer exists") unless to

            return add(verdict, user, to) if action == "add"

            from = GoodreadsReplay::Apply::MergedBook.call(payload["from_book_id"])
            return Entries.noop("nothing to move") unless from
            return Entries.noop("both books were merged into book #{to.id}") if from.id == to.id

            (action == "move") ? move(verdict, user, from, to) : copy(verdict, user, from, to)
          end

          def self.add(verdict, user, to)
            row = csv_row(verdict)
            return Entries.noop("import row #{verdict.payload["import_id"]}:#{verdict.payload["row_number"]} no longer exists") unless row

            before = snapshot(user, to)
            result = ::ApplicationRecord.transaction { write(user, row, to, review: verdict.payload["review"] == true) }
            return Entries.noop("the user's lists already hold the book") if snapshot(user, to) == before

            Entries.record_moved(verdict, "list_item_ids_before" => before.first.map(&:first), "list_item_ids_after" => result[:list_item_ids],
              "review_id_before" => before.last, "review_id_after" => Entries.review_on(user, to)&.id)
            Entries.applied(Entries.favorites_follow_ups(items_by_id(result[:list_item_ids]), [to]))
          end

          def self.move(verdict, user, from, to)
            items = Entries.items_on(user, from)
            review = carried_review(verdict, user, from)
            return Entries.noop("nothing to move") if items.empty? && review.nil?

            urls = Entries.goal_urls(user, items)
            afters = []
            review_after = nil
            ::ApplicationRecord.transaction do
              afters = items.map { |item| Entries.move_item(item, to) }
              review_after = Entries.move_review(review, user, to) if review
              Entries.record_moved(verdict, "list_item_ids_before" => items.map(&:id), "list_item_ids_after" => afters,
                "review_id_before" => review&.id, "review_id_after" => review_after)
            end
            recalculate(from, to) if review
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
            Entries.applied(Entries.favorites_follow_ups(items, [from, to]))
          end

          def self.copy(verdict, user, from, to)
            row = csv_row(verdict)
            return Entries.noop("import row #{verdict.payload["import_id"]}:#{verdict.payload["row_number"]} no longer exists") unless row

            items = Entries.items_on(user, from)
            review = carried_review(verdict, user, from)
            return Entries.noop("nothing to move") if items.empty? && review.nil?

            before = snapshot(user, to)
            result = nil
            review_after = nil
            ::ApplicationRecord.transaction do
              # The CSV's review is written only when there is none to move: a review is moved, never doubled.
              result = write(user, row, to, review: verdict.payload["review"] == true && review.nil?)
              review_after = Entries.move_review(review, user, to) if review
              Entries.record_moved(verdict, "list_item_ids_before" => before.first.map(&:first), "list_item_ids_after" => result[:list_item_ids],
                "review_id_before" => review&.id, "review_id_after" => review_after || result[:review_id])
            end
            recalculate(from, to) if review
            Entries.applied(Entries.favorites_follow_ups(items_by_id(result[:list_item_ids]), [from, to]))
          end

          def self.csv_row(verdict)
            ::Books::GoodreadsImportRow.includes(:import).find_by(import_id: verdict.payload["import_id"], row_number: verdict.payload["row_number"])
          end

          # The review the row carries off the old book: only for review: true, and only if it still exists.
          def self.carried_review(verdict, user, from)
            Entries.review_on(user, from) if verdict.payload["review"] == true
          end

          def self.write(user, row, book, review:)
            GoodreadsImports::LibraryRules.write_row(user: user, row: row, book: book, fallback_created_at: row.import.created_at, review: review)
          end

          # The user's lists items and review on one book, to see whether a write changed anything.
          def self.snapshot(user, book)
            [Entries.items_on(user, book).map { |item| [item.id, item.completed_on] }, Entries.review_on(user, book)&.id]
          end

          def self.items_by_id(ids) = ::UserListItem.where(id: ids).includes(:user_list).to_a

          def self.recalculate(*books)
            books.each { |book| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", book.id) }
          end

          private_class_method :add, :move, :copy, :csv_row, :carried_review, :write, :snapshot, :items_by_id, :recalculate
        end
      end
    end
  end
end
