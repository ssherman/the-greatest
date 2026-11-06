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
        # - keep (and any superseded row): nothing, except that a keep carrying the review takes the CSV's rating
        #   (see rate). Every verdict that carries the review does, after its own work.
        #   A final no-op: the verdict is applied, so DecideRow and the author check see the row.
        # - add: the row's entries on the destination, by LibraryRules; a list that already holds the book is
        #   left as it is (a final no-op). review: true writes the CSV's rating and review.
        # - move: ALL the user's items on the old book (every list) go to the destination, with Relink's
        #   collision rules. The user's review goes only when review: true.
        # - copy: the row's entries are created on the destination, dated from this row; the old book's items
        #   stay (the mixed-book delete or a later move removes them). review: true carries the user's review
        #   from the old book (moved); with none there, the CSV's is written. A row that does not carry it
        #   writes its own CSV rating and review, when it has any (spec 8 call 2).
        # A user has one review per book. An existing review on the destination wins its title and body, but not its
        # rating: the carrying row's CSV rating (> 0) is set on it (see rate).
        class Row
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?

            payload = verdict.payload
            action = payload["action"]
            return Entries.noop("superseded by #{payload["superseded_by"]}", final: true) if payload["superseded_by"].present?
            return Entries.noop("unknown action #{action.inspect}") unless %w[keep add move copy].include?(action)

            # Before the keep return: a keep closed on a since-rejected match could never be corrected.
            return Entries.noop("match no longer approved") unless Entries.match_approved?(payload["goodreads_edition_id"])
            return Entries.noop("keep", final: true) if action == "keep" && payload["review"] != true

            keep = action == "keep"
            user = ::User.find_by(id: payload["user_id"])
            # A keep closes as it always did when the reader or book is gone: there is no rating left to set.
            return Entries.noop("keep", final: true) if keep && !user
            return Entries.noop("user #{payload["user_id"]} no longer exists") unless user

            to = GoodreadsReplay::Apply::MergedBook.call(payload["to_book_id"])
            return Entries.noop("keep", final: true) if keep && !to
            return Entries.noop("book #{payload["to_book_id"]} no longer exists") unless to

            return rate(verdict, user, to, add(verdict, user, to)) if action == "add"
            return rate(verdict, user, to, Entries.noop("keep", final: true)) if keep

            from = GoodreadsReplay::Apply::MergedBook.call(payload["from_book_id"])
            return nothing_to_move(verdict) unless from
            # The row's destination is the very book its entries are on (a mixed book that stayed matchable, or two
            # merged books): nothing moves, but this row's own shelf, dates and review still belong on it.
            result = if from.id == to.id
              in_place(verdict, user, to)
            elsif action == "move"
              move(verdict, user, from, to)
            else
              copy(verdict, user, from, to)
            end
            reopen_kept(from) if result.data[:outcome] == :applied
            rate(verdict, user, to, result)
          end

          # The CSV's rating wins: the review the carrying row (review: true) points at takes its rating when
          # that is above 0 ("not rated" leaves the review alone) and differs. The old rating goes in the trail.
          # A final no-op (a keep, or entries already in place) becomes applied when the rating changed; any other
          # outcome keeps its own result, and its retry finds the rating already set.
          def self.rate(verdict, user, to, result)
            return result unless verdict.payload["review"] == true
            settled = result.data[:outcome] == :applied || (result.data[:outcome] == :noop && result.data[:final])
            return result unless settled

            row = csv_row(verdict)
            review = Entries.review_on(user, to)
            return result unless row && review && row.rating.to_f > 0 && review.rating != row.rating

            before = review.rating
            ::ApplicationRecord.transaction do
              review.update!(rating: row.rating)
              moved = verdict.payload["moved"].is_a?(Hash) ? verdict.payload["moved"] : {}
              verdict.update_columns(payload: verdict.payload.merge("moved" => moved.merge("rating_before" => before&.to_s)))
            end
            recalculate(to)
            return result if result.data[:outcome] == :applied

            Entries.applied(rating_changed: true)
          end

          # A kept mixed book's keep step (Apply::Mixed) removes copy originals once every copy from it has applied. A
          # copy or move that applies after that step closed would leave its original behind, so the step runs again.
          def self.reopen_kept(from)
            mixed = ::Books::RepairVerdict.reimport_mixed.approved.current.where.not(applied_at: nil)
              .find_by(subject_key: "reimport:book:#{from.id}")
            return unless mixed&.payload&.dig("kept")

            mixed.update_columns(applied_at: nil, payload: mixed.payload.except("closed_reason"))
          end

          def self.in_place(verdict, user, to)
            row = csv_row(verdict)
            return Entries.noop("import row #{verdict.payload["import_id"]}:#{verdict.payload["row_number"]} no longer exists") unless row

            explained = []
            result = add(verdict, user, to, review: writes_csv_review?(verdict, row, nil), explained: explained)
            # The items on the book that this row's shelves account for. When the book stays (a kept mixed book),
            # Apply::Mixed removes the user's other copy originals and must leave these alone.
            verdict.update_columns(payload: verdict.payload.merge("explained_item_ids" => explained.uniq.sort))
            result
          end

          def self.add(verdict, user, to, review: verdict.payload["review"] == true, explained: nil)
            row = csv_row(verdict)
            return Entries.noop("import row #{verdict.payload["import_id"]}:#{verdict.payload["row_number"]} no longer exists") unless row

            before = snapshot(user, to)
            trail = Entries.new_trail
            result = nil
            ::ApplicationRecord.transaction do
              result = write(user, row, to, trail, review: review)
              explained&.concat(result[:list_item_ids])
              if snapshot(user, to) != before
                Entries.record_moved(verdict, "list_item_ids_before" => before.first.map(&:first), "list_item_ids_after" => result[:list_item_ids],
                  "review_id_before" => before.last, "review_id_after" => Entries.review_on(user, to)&.id, **trail)
              end
            end
            if snapshot(user, to) == before
              return Entries.moved?(verdict) ? Entries.applied : Entries.noop("the user's lists already hold the book", final: true)
            end

            Entries.applied(Entries.favorites_follow_ups(items_by_id(result[:list_item_ids]), [to]))
          end

          def self.move(verdict, user, from, to)
            items = Entries.items_on(user, from)
            review = carried_review(verdict, user, from)
            return nothing_to_move(verdict) if items.empty? && review.nil?

            urls = Entries.goal_urls(user, items)
            trail = Entries.new_trail
            afters = []
            review_after = nil
            ::ApplicationRecord.transaction do
              afters = items.map { |item| Entries.move_item(item, to, trail) }
              review_after = Entries.move_review(review, user, to, trail) if review
              Entries.record_moved(verdict, "list_item_ids_before" => items.map(&:id), "list_item_ids_after" => afters,
                "review_id_before" => review&.id, "review_id_after" => review_after, **trail)
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
            return nothing_to_move(verdict) if items.empty? && review.nil?

            before = snapshot(user, to)
            trail = Entries.new_trail
            ids = []
            review_id = nil
            ::ApplicationRecord.transaction do
              # See writes_csv_review?: a review is moved or written, never doubled.
              result = write(user, row, to, trail, review: writes_csv_review?(verdict, row, review))
              ids = result[:list_item_ids] + copy_other_lists(items, to)
              review_id = review ? Entries.move_review(review, user, to, trail) : result[:review_id]
              Entries.record_moved(verdict, "list_item_ids_before" => before.first.map(&:first), "list_item_ids_after" => ids,
                "review_id_before" => review&.id, "review_id_after" => review_id, **trail)
            end
            recalculate(from, to) if review
            Entries.applied(Entries.favorites_follow_ups(items_by_id(ids), [from, to]))
          end

          # Nothing left on the old book. If this verdict already recorded a move, a crash lost only its applied_at,
          # and it is done; otherwise there was never anything to move.
          def self.nothing_to_move(verdict) = Entries.moved?(verdict) ? Entries.applied : Entries.noop("nothing to move")

          # The CSV's review is written when the row carries the review and there is none to move (a review is
          # moved, never doubled), or when it does not carry it but has a rating or text of its own: that review
          # belongs to this row's book. write_review refuses when the user already has one on the destination.
          def self.writes_csv_review?(verdict, row, moved_review)
            return moved_review.nil? if verdict.payload["review"] == true

            (row.rating.to_f > 0 || row.review_body.present?) && !sibling_carries?(verdict)
          end

          # Another row of the same reader, from the same old book to the same destination, carries the moved
          # review. It wins whichever applies first, so this row must not write a CSV review there before it.
          def self.sibling_carries?(verdict)
            p = verdict.payload
            ::Books::RepairVerdict.reimport_row.current.where.not(id: verdict.id)
              .where("payload->>'user_id' = ? AND payload->>'from_book_id' = ? AND payload->>'to_book_id' = ? AND payload->>'review' = 'true'",
                p["user_id"].to_s, p["from_book_id"].to_s, p["to_book_id"].to_s).exists?
          end

          # The row's shelves are only some of the lists the old book was on: Favorites and hand-made lists
          # are not shelves, and the old book's items go when it is deleted. Each of those lists gets the
          # destination too, dated as its own item was; one that already holds it is skipped. Read, Want to
          # Read and Reading are never copied: the row's own shelves (write_row) decide them, so a to-read row
          # cannot leave the destination on Read with the old book's date. None of these lists counts toward a
          # reading goal, so no goal page needs purging.
          def self.copy_other_lists(items, to)
            copied = items.filter_map do |item|
              list = item.user_list
              next unless [:favorites, :custom].include?(list.try(:list_type)&.to_sym)
              next if ::UserListItem.exists?(user_list_id: item.user_list_id, listable_type: "Books::Book", listable_id: to.id)

              position = ::UserListItem.where(user_list_id: item.user_list_id).maximum(:position).to_i + 1
              ::UserListItem.create!(user_list_id: item.user_list_id, listable_type: "Books::Book", listable_id: to.id,
                completed_on: item.completed_on, position: position, created_at: item.created_at)
            end
            ::UserList.where(id: copied.map(&:user_list_id)).touch_all if copied.any?
            copied.map(&:id)
          end

          def self.csv_row(verdict)
            ::Books::GoodreadsImportRow.includes(:import).find_by(import_id: verdict.payload["import_id"], row_number: verdict.payload["row_number"])
          end

          # The review the row carries off the old book: only for review: true, and only if it still exists.
          def self.carried_review(verdict, user, from)
            Entries.review_on(user, from) if verdict.payload["review"] == true
          end

          # write_row removes the reading item of a book the row says is read; capture it first.
          def self.write(user, row, book, trail, review:)
            held = Entries.items_on(user, book).index_by(&:id)
            result = GoodreadsImports::LibraryRules.write_row(user: user, row: row, book: book, fallback_created_at: row.import.created_at, review: review)
            (held.keys - ::UserListItem.where(id: held.keys).pluck(:id)).each { |id| trail["destroyed_items"] << Entries.item_attributes(held[id]) }
            result
          end

          # The user's lists items and review on one book, to see whether a write changed anything.
          def self.snapshot(user, book)
            [Entries.items_on(user, book).map { |item| [item.id, item.completed_on] }, Entries.review_on(user, book)&.id]
          end

          def self.items_by_id(ids) = ::UserListItem.where(id: ids).includes(:user_list).to_a

          def self.recalculate(*books)
            books.each { |book| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", book.id) }
          end

          private_class_method :reopen_kept, :rate, :in_place, :add, :move, :copy, :copy_other_lists, :nothing_to_move, :writes_csv_review?, :sibling_carries?, :csv_row, :carried_review, :write, :snapshot, :items_by_id, :recalculate
        end
      end
    end
  end
end
