# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a relink verdict (Goodreads import spec §12.4): moves one
        # user's list items and review from the book legacy chose to the one the
        # resolver found.
        # - A list that already holds the right book keeps that item, with its
        #   blank completed_on filled from the wrong one's.
        # - A review the user already wrote on the right book wins.
        # - When legacy's identifier was the mistake, the row's identifiers move
        #   too.
        # When another of the user's replay rows still names the wrong book (its
        # Goodreads id is on that book and no approved relink moves it), the book
        # is right for that row: the right book is added beside it on the same
        # lists, and the wrong book's items and review stay.
        # Never touches another user's items. Idempotent: nothing left to move or
        # add is a no-op.
        class Relink
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            new(verdict.payload).call
          end

          # Does another of this user's replay rows name from_book? Legacy stamped
          # each row's Goodreads id on the book it chose, so a Goodreads id on the
          # book that one of the user's rows carries, and that no approved relink
          # of theirs moves off it, is a row the book still serves.
          def self.supported_elsewhere?(user_id:, from_book:, goodreads_book_id:)
            relinked = ::Books::RepairVerdict.relink.approved
              .where("payload->>'user_id' = ? AND payload->>'from_book_id' = ?", user_id.to_s, from_book.id.to_s)
              .pluck(Arel.sql("payload->>'goodreads_book_id'"))
            held = from_book.identifiers.where(identifier_type: :books_work_goodreads_id).pluck(:value).filter_map { |value| value[/\A\d+/] }
            others = (held - relinked - [goodreads_book_id.to_s]).uniq
            return false if others.empty?

            ::Books::GoodreadsImportRow.joins(:import, :goodreads_edition).merge(::Books::GoodreadsImport.legacy_replay)
              .where(books_goodreads_imports: {user_id: user_id}, books_goodreads_editions: {goodreads_book_id: others}).exists?
          end

          def initialize(payload)
            @payload = payload
          end

          def call
            user = ::User.find_by(id: @payload["user_id"])
            return noop("user #{@payload["user_id"]} no longer exists") unless user

            from = ::Books::Book.find_by(id: @payload["from_book_id"])
            to = ::Books::Book.find_by(id: @payload["to_book_id"])
            missing = [[from, "from_book_id"], [to, "to_book_id"]].find { |book, _| book.nil? }
            return noop("book #{@payload[missing.last]} no longer exists") if missing

            items = ::UserListItem.joins(:user_list).where(user_lists: {user_id: user.id}, listable: from).to_a
            keep = self.class.supported_elsewhere?(user_id: user.id, from_book: from, goodreads_book_id: @payload["goodreads_book_id"])
            review = keep ? nil : ::Review.find_by(user: user, reviewable: from)
            goal_urls = keep ? [] : reading_goal_urls(user, items)
            changed = 0
            ActiveRecord::Base.transaction do
              changed += items.count { |item| keep ? copy_item(item, to) : move_item(item, to) }
              move_review(review, user, to) if review
              changed += StripIdentifier.change(book: from, remove: Array(@payload["strip_identifiers"]), add: []) +
                StripIdentifier.change(book: to, remove: [], add: Array(@payload["stamp_identifiers"]))
            end
            return noop("already applied") if review.nil? && changed.zero?

            ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", from.id) if review
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", goal_urls) if goal_urls.any?
            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          private

          # True: something changed.
          def move_item(item, to)
            kept = ::UserListItem.find_by(user_list_id: item.user_list_id, listable: to)
            if kept
              kept.update!(completed_on: item.completed_on) if kept.completed_on.nil? && item.completed_on
              item.destroy!
            else
              item.update!(listable: to)
            end
            true
          end

          # True: the right book was added to the item's list.
          def copy_item(item, to)
            return false if ::UserListItem.exists?(user_list_id: item.user_list_id, listable: to)

            ::UserListItem.create!(user_list_id: item.user_list_id, listable: to, completed_on: item.completed_on)
            true
          end

          def move_review(review, user, to)
            ::Review.exists?(user: user, reviewable: to) ? review.destroy! : review.update!(reviewable: to)
          end

          # Public goal pages that list the wrong book among this user's reads,
          # captured before the move (as Books::Book::Merger does): the count is
          # unchanged, the book shown is not.
          def reading_goal_urls(user, items)
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

          def noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end
        end
      end
    end
  end
end
