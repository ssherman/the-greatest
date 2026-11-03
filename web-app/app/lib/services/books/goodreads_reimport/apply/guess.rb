# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_guess verdict (re-import spec 4.3): one hand-added list item or review on a mixed
        # book, which no CSV row explains, goes to the book the guess named. The same collision rules as Relink.
        # Checks where the entry is now, not what the payload says: an entry that has already left the book,
        # or that is not this user's, is a no-op.
        class Guess
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?

            payload = verdict.payload
            user = ::User.find_by(id: payload["user_id"])
            return Entries.noop("user #{payload["user_id"]} no longer exists") unless user

            from = GoodreadsReplay::Apply::MergedBook.call(payload["from_book_id"])
            to = GoodreadsReplay::Apply::MergedBook.call(payload["to_book_id"])
            return Entries.noop("book #{payload["to_book_id"]} no longer exists") unless to
            return nothing_to_move(verdict) unless from
            return Entries.noop("both books were merged into book #{to.id}") if from.id == to.id
            return Entries.noop("match no longer approved") unless destination_supported?(from, to)

            (payload["item_type"] == "Review") ? move_review(verdict, user, from, to) : move_item(verdict, user, from, to)
          end

          # A crash after the move recorded its trail lost only applied_at: that is done, not "nothing to move".
          def self.nothing_to_move(verdict) = Entries.moved?(verdict) ? Entries.applied : Entries.noop("nothing to move")

          # The guess names the book most of the mixed book's rows went to. When those rows' decisions exist and
          # every one of their matches has been rejected since, the destination is no longer anyone's answer.
          def self.destination_supported?(from, to)
            editions = ::Books::RepairVerdict.reimport_row.current
              .where("payload->>'from_book_id' = ? AND payload->>'to_book_id' = ?", from.id.to_s, to.id.to_s)
              .pluck(Arel.sql("payload->>'goodreads_edition_id'")).compact
            editions.empty? || editions.any? { |id| Entries.match_approved?(id) }
          end

          def self.move_item(verdict, user, from, to)
            item = Entries.items_on(user, from).find { |candidate| candidate.id == verdict.payload["item_id"].to_i }
            return nothing_to_move(verdict) unless item

            urls = Entries.goal_urls(user, [item])
            trail = Entries.new_trail
            ::UserListItem.transaction do
              after = Entries.move_item(item, to, trail)
              Entries.record_moved(verdict, "list_item_ids_before" => [item.id], "list_item_ids_after" => [after],
                "review_id_before" => nil, "review_id_after" => nil, **trail)
            end
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
            Entries.applied(Entries.favorites_follow_ups([item], [from, to]))
          end

          def self.move_review(verdict, user, from, to)
            review = ::Review.find_by(id: verdict.payload["item_id"], user_id: user.id, reviewable_type: "Books::Book", reviewable_id: from.id)
            return nothing_to_move(verdict) unless review

            trail = Entries.new_trail
            ::Review.transaction do
              after = Entries.move_review(review, user, to, trail)
              Entries.record_moved(verdict, "list_item_ids_before" => [], "list_item_ids_after" => [],
                "review_id_before" => review.id, "review_id_after" => after, **trail)
            end
            ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", from.id)
            ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", to.id)
            Entries.applied
          end

          private_class_method :nothing_to_move, :destination_supported?, :move_item, :move_review
        end
      end
    end
  end
end
