# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # An admin's approval of a finished member import (Goodreads import spec
      # §10, R5):
      #
      # 1. Unticked records are deleted, when still provisional and nothing
      #    else uses them (DeleteProvisional); a record something else uses is
      #    kept and reported.
      # 2. Every provisional book the import created or its editions link to
      #    is promoted, with its provisional authors, and so is every
      #    provisional author it created (PromoteRecords). An unticked author
      #    still credited on a promoted book is promoted with it.
      # 3. Enrichment is queued (PromoteRecords).
      #
      # A provisional book several imports reference is promoted by whichever
      # is approved first.
      class Approve
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:, reviewer:, exclude_book_ids: [], exclude_author_ids: [])
          new(import: import, reviewer: reviewer, exclude_book_ids: exclude_book_ids, exclude_author_ids: exclude_author_ids).call
        end

        def initialize(import:, reviewer:, exclude_book_ids:, exclude_author_ids:)
          @import = import
          @reviewer = reviewer
          @exclude_book_ids = Array(exclude_book_ids).map(&:to_i).to_set
          @exclude_author_ids = Array(exclude_author_ids).map(&:to_i).to_set
        end

        def call
          refusal = nil
          kept = []
          deleted = []
          promoted = nil
          ActiveRecord::Base.transaction do
            # Checked under the lock, on the reloaded row: a reject that
            # committed first wins over this approval.
            @import.lock!
            refusal = refusal_reason
            next if refusal

            excluded_records.each do |record|
              result = DeleteProvisional.call(import: @import, record: record)
              result.data[:deleted] ? deleted << [record.id, record.class.name] : kept << [record.id, result.errors.first]
            end
            books = promotable_books
            authors = promotable_authors(books)
            authors.each { |author| kept << [author.id, "Kept: still credited on a promoted book."] if @exclude_author_ids.include?(author.id) && credited_on?(author, books) }
            promoted = PromoteRecords.call(books: books, authors: authors.reject { |author| @exclude_author_ids.include?(author.id) && !credited_on?(author, books) })
            @import.update!(review_status: :approved, reviewed_by: @reviewer, reviewed_at: Time.current)
          end
          return Result.new(success?: false, data: {}, errors: [refusal]) if refusal

          data = {
            promoted_book_ids: promoted.data[:book_ids],
            promoted_author_ids: promoted.data[:author_ids],
            deleted: deleted,
            kept: kept.uniq
          }
          Result.new(success?: true, data: data, errors: [])
        end

        private

        def refusal_reason
          return "Only member imports are approved here." unless @import.member?
          return "Only a finished import can be approved." unless @import.complete?
          "This import is already #{@import.review_status}." unless @import.review_pending?
        end

        # Only records this import created can be unticked: an approval is
        # not a way to delete any provisional record by id.
        def excluded_records
          created = @import.records.created
          ::Books::Book.where(id: @exclude_book_ids.to_a).where(id: created.where(record_type: "Books::Book").select(:record_id)).to_a +
            ::Books::Author.where(id: @exclude_author_ids.to_a).where(id: created.where(record_type: "Books::Author").select(:record_id)).to_a
        end

        def promotable_books
          ids = @import.records.created.where(record_type: "Books::Book").select(:record_id)
          ::Books::Book.where(provisional: true).where(id: ids)
            .or(::Books::Book.where(provisional: true).where(id: @import.editions.select(:book_id)))
            .where.not(id: @exclude_book_ids.to_a).includes(:authors, :book_authors).to_a
        end

        def promotable_authors(books)
          ids = @import.records.created.where(record_type: "Books::Author").select(:record_id)
          (::Books::Author.where(provisional: true, id: ids).to_a + books.flat_map(&:authors).select(&:provisional?)).uniq
        end

        def credited_on?(author, books)
          books.any? { |book| book.book_authors.any? { |book_author| book_author.author_id == author.id } }
        end
      end
    end
  end
end
