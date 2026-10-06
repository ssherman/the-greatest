# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # An admin's rejection of a member import (Goodreads import spec §10):
      #
      # - deletes the list items and reviews every row's `applied` names;
      # - deletes the provisional books and authors the import created that
      #   nothing else uses (ProvisionalReferences);
      # - removes identifiers it stamped onto existing books;
      # - recalculates review summaries and purges goal pages it touched.
      #
      # What it changed rather than inserted stays (R3): a reading item a read
      # row replaced, a blank date it filled. A stuck import is failed as it is
      # rejected, which frees the member to upload again.
      class Revert
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:, reviewer:)
          new(import: import, reviewer: reviewer).call
        end

        def initialize(import:, reviewer:)
          @import = import
          @reviewer = reviewer
        end

        def call
          refusal = nil
          data = nil
          purge_urls = []
          book_ids = []
          ActiveRecord::Base.transaction do
            # Checked under the lock, on the reloaded row, so two admins'
            # clicks never both act.
            @import.lock!
            refusal = refusal_reason
            next if refusal

            # The member's row lock, which WriteLibrary holds for its whole
            # write: a worker still writing commits first, so its `applied`
            # ids are read below; one that starts after sees the rejection
            # and writes nothing.
            ::User.lock.find(@import.user_id)
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_user(user: @import.user)
            item_ids = @import.applied_ids("list_item_ids")
            review_ids = @import.applied_ids("review_id")
            book_ids = ::Review.where(id: review_ids).pluck(:reviewable_id)
            list_ids = ::UserListItem.where(id: item_ids).distinct.pluck(:user_list_id)
            deleted_items = ::UserListItem.where(id: item_ids).delete_all
            deleted_reviews = ::Review.where(id: review_ids).delete_all
            list_ids.each { |list_id| ::UserListItem.renumber(list_id) }
            ::UserList.where(id: list_ids).touch_all if list_ids.any?
            @import.rows.where("applied != '{}'::jsonb").update_all(applied: {}, updated_at: Time.current)
            deleted_books = delete_books
            deleted_authors = delete_authors
            ::Identifier.where(id: @import.records.stamped.where(record_type: "Identifier").select(:record_id)).destroy_all
            # Editions still waiting on their page settle for another import,
            # or are released, never created for this one.
            @import.pending_editions.update_all(pending_import_id: nil, updated_at: Time.current)
            close!
            data = {deleted_items: deleted_items, deleted_reviews: deleted_reviews, deleted_book_ids: deleted_books,
                    deleted_author_ids: deleted_authors}
          end
          return Result.new(success?: false, data: {}, errors: [refusal]) if refusal

          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          book_ids.uniq.each { |id| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", id) }
          Result.new(success?: true, data: data, errors: [])
        end

        private

        def refusal_reason
          return "Only member imports are rejected here." unless @import.member?
          return "This import is already rejected." if @import.review_rejected?
          "This import is still running. Wait for it to finish, or for it to be flagged stuck." if @import.in_progress? && !@import.stuck?
        end

        def delete_books
          ids = @import.records.created.where(record_type: "Books::Book").select(:record_id)
          ::Books::Book.where(id: ids, provisional: true).to_a.filter_map do |book|
            next if ProvisionalReferences.book_used_elsewhere?(book, import: @import)

            book.destroy!
            book.id
          end
        end

        def delete_authors
          ids = @import.records.created.where(record_type: "Books::Author").select(:record_id)
          ::Books::Author.where(id: ids, provisional: true).to_a.filter_map do |author|
            next if ProvisionalReferences.author_used?(author)

            author.destroy!
            author.id
          end
        end

        def close!
          attributes = {review_status: :rejected, reviewed_by: @reviewer, reviewed_at: Time.current}
          attributes.merge!(status: :failed, error: "rejected while stuck", finished_at: Time.current) if @import.in_progress?
          @import.update!(attributes)
        end
      end
    end
  end
end
