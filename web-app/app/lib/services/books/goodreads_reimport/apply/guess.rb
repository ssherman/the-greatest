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
            return Entries.noop("nothing to move") unless from
            return Entries.noop("both books were merged into book #{to.id}") if from.id == to.id

            (payload["item_type"] == "Review") ? move_review(verdict, user, from, to) : move_item(verdict, user, from, to)
          end

          def self.move_item(verdict, user, from, to)
            item = Entries.items_on(user, from).find { |candidate| candidate.id == verdict.payload["item_id"].to_i }
            return Entries.noop("nothing to move") unless item

            urls = Entries.goal_urls(user, [item])
            ::UserListItem.transaction do
              after = Entries.move_item(item, to)
              Entries.record_moved(verdict, "list_item_ids_before" => [item.id], "list_item_ids_after" => [after],
                "review_id_before" => nil, "review_id_after" => nil)
            end
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
            Entries.applied(Entries.favorites_follow_ups([item], [from, to]))
          end

          def self.move_review(verdict, user, from, to)
            review = ::Review.find_by(id: verdict.payload["item_id"], user_id: user.id, reviewable_type: "Books::Book", reviewable_id: from.id)
            return Entries.noop("nothing to move") unless review

            ::Review.transaction do
              after = Entries.move_review(review, user, to)
              Entries.record_moved(verdict, "list_item_ids_before" => [], "list_item_ids_after" => [],
                "review_id_before" => review.id, "review_id_after" => after)
            end
            ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", from.id)
            ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", to.id)
            Entries.applied
          end

          private_class_method :move_item, :move_review
        end
      end
    end
  end
end
