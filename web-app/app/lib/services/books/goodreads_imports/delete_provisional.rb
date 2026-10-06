# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Deletes one provisional book or author an import created, with what
      # the import wrote for it: the member's list items and review (spec §10,
      # Approve step 1 and per record). A record anything else uses stays
      # (ProvisionalReferences), and an approved record is never deleted here.
      #
      # The book's editions lose it (FK nullify) and are resolved afresh by
      # the next import that names them. Rows that wrote for it read "removed
      # by an admin". An author the import created and left with no book goes
      # too.
      class DeleteProvisional
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        REMOVED_DETAIL = "removed by an admin"

        def self.call(import:, record:)
          new(import: import, record: record).call
        end

        def initialize(import:, record:)
          @import = import
          @record = record
        end

        def call
          return kept("it is already approved") unless @record.provisional?

          case @record
          when ::Books::Book then delete_book
          when ::Books::Author then delete_author
          else kept("only books and authors can be deleted here")
          end
        end

        private

        def delete_book
          return kept("another import, list or review uses it") if ProvisionalReferences.book_used_elsewhere?(@record, import: @import)

          purge_urls = []
          ActiveRecord::Base.transaction do
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: @record)
            item_ids = @record.user_list_items.pluck(:id)
            review_ids = ::Review.where(reviewable: @record).pluck(:id)
            release_rows(item_ids, review_ids)
            author_ids = @import.records.created.where(record_type: "Books::Author").pluck(:record_id)
            @record.destroy!
            ::Books::Author.where(id: author_ids, provisional: true).where.missing(:book_authors).find_each(&:destroy!)
          end
          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          deleted
        end

        def delete_author
          return kept("it is still credited on a book") if ProvisionalReferences.author_used?(@record)

          @record.destroy!
          deleted
        end

        # The rows that wrote these items or this review stop recording them.
        def release_rows(item_ids, review_ids)
          @import.rows.where("applied != '{}'::jsonb").find_each do |row|
            items = Array(row.applied["list_item_ids"]).map(&:to_i)
            review = row.applied["review_id"]&.to_i
            next unless items.intersect?(item_ids) || review_ids.include?(review)

            applied = row.applied.merge("list_item_ids" => items - item_ids)
            applied.delete("review_id") if review_ids.include?(review)
            applied = applied.reject { |_key, value| value.blank? }
            row.update!(applied: applied, outcome: applied.empty? ? :skipped : row.outcome,
              outcome_detail: applied.empty? ? REMOVED_DETAIL : row.outcome_detail)
          end
        end

        def kept(reason)
          Result.new(success?: false, data: {deleted: false}, errors: ["Kept: #{reason}."])
        end

        def deleted
          Result.new(success?: true, data: {deleted: true}, errors: [])
        end
      end
    end
  end
end
