# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # What Row and Guess share when they move a reader's entries between books: Relink's collision rules
        # (GoodreadsReplay::Apply::Relink), which stay private there. A list that already holds the destination
        # keeps its item, with a blank completed_on filled from the moved one; a review the user already has on
        # the destination wins.
        module Entries
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          module_function

          def items_on(user, book)
            ::UserListItem.joins(:user_list).where(user_lists: {user_id: user.id}, listable_type: "Books::Book", listable_id: book.id)
              .includes(:user_list).order(:id).to_a
          end

          def review_on(user, book) = ::Review.find_by(user: user, reviewable_type: "Books::Book", reviewable_id: book.id)

          def new_trail = {"destroyed_items" => [], "destroyed_reviews" => []}

          # Everything a destroyed record held, so the verdict can put it back by hand.
          def item_attributes(item) = item.attributes.slice("id", "user_list_id", "listable_id", "position", "completed_on", "created_at")

          def review_attributes(review) = review.attributes.slice("id", "user_id", "reviewable_id", "rating", "title", "body", "created_at", "updated_at")

          # Returns the id the entry has on the destination afterwards. A destroyed item is added to the trail.
          def move_item(item, to, trail)
            kept = ::UserListItem.find_by(user_list_id: item.user_list_id, listable_type: "Books::Book", listable_id: to.id)
            if kept
              kept.update!(completed_on: item.completed_on) if kept.completed_on.nil? && item.completed_on
              trail["destroyed_items"] << item_attributes(item)
              item.destroy!
              kept.id
            else
              item.update!(listable: to)
              item.id
            end
          end

          # Returns the id the user's review of the destination has afterwards.
          def move_review(review, user, to, trail)
            existing = review_on(user, to)
            if existing
              trail["destroyed_reviews"] << review_attributes(review)
              review.destroy!
              existing.id
            else
              review.update!(reviewable: to)
              review.id
            end
          end

          # Public goal pages that list the moved book among this user's reads, captured before the move:
          # the count is unchanged, the book shown is not.
          def goal_urls(user, items)
            items.select { |item| item.completed_on && item.user_list.is_a?(::Books::UserList) && item.user_list.read? }
              .flat_map do |item|
                user.books_reading_goals.public_goals
                  .where("starts_on <= ? AND ends_on >= ?", item.completed_on, item.completed_on).order(:id)
                  .flat_map do |goal|
                    count = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal).count
                    ::Services::Books::ReadingGoals::CachedUrls.call(goal: goal, count: count)
                  end
              end.uniq
          end

          # A favorite that changed alters the generated "Users' Favorite Books" list and the rankings it feeds.
          def favorites_follow_ups(items, books)
            return {} unless items.any? { |item| item.user_list.is_a?(::Books::UserList) && item.user_list.favorites? }

            ranked = ::RankedItem.where(item_type: "Books::Book", item_id: books.map(&:id)).distinct.pluck(:ranking_configuration_id)
            {follow_ups: [:user_favorites],
             reweigh_configuration_ids: (ranked + [::Books::RankingConfiguration.default_primary&.id]).compact.uniq}
          end

          # final: true says nothing will ever change this answer (the thing to act on is already gone), so the
          # orchestrator marks the verdict done instead of offering it again on every run.
          def noop(reason, final: false) = Result.new(success?: true, data: {outcome: :noop, reason: reason, final: final}, errors: [])

          def applied(extra = {}) = Result.new(success?: true, data: {outcome: :applied}.merge(extra), errors: [])

          # The audit trail the verdict keeps: ids before and after, so a wrong move can be read back.
          def record_moved(verdict, moved)
            verdict.update_columns(payload: verdict.payload.merge("moved" => moved))
          end
        end
      end
    end
  end
end
