# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One repair verdict with what an agent needs to judge it: the payload, the books and authors it names, a
        # re-import match's candidate books, the linked match decision and a capped sample of the import rows it came
        # from. Books load once with their authors, so the detail is a fixed number of queries. Key order is the order
        # in config/api/v1/admin_openapi.yaml. Root-anchor every ::Books:: reference in this namespace.
        class RepairVerdictDetailResource < RepairVerdictResource
          SOURCE_ROW_LIMIT = 20

          def initialize(verdict)
            super
            @books = ::Books::Book.where(id: verdict.book_ids + candidate_ids).includes(:authors).index_by(&:id)
          end

          def to_h
            super.merge(
              payload: @verdict.payload,
              ai_chat_id: @verdict.ai_chat_id,
              reviewed_by: reviewer,
              reviewed_via: @verdict.reviewed_via,
              superseded_at: @verdict.superseded_at,
              books: book_hashes(@verdict.book_ids),
              authors: authors,
              candidate_books: book_hashes(candidate_ids),
              match_decision: match_decision,
              source_rows: source_rows,
              source_row_count: ::Services::Books::RepairVerdicts::SourceRows.pairs(@verdict).size
            )
          end

          private

          def candidate_ids = Array(@verdict.payload["candidate_book_ids"]).select { |id| id.is_a?(Integer) }.uniq

          def book_hashes(ids)
            ids.filter_map { |id| @books[id] }.map do |book|
              {
                id: book.id, slug: book.slug, title: book.title, first_published_year: book.first_published_year,
                authors: book.authors.map { |author| ::Api::V1::Books::AuthorSummaryResource.new(author).to_h }
              }
            end
          end

          def authors
            ::Books::Author.where(id: @verdict.author_ids).map { |author| ::Api::V1::Books::AuthorSummaryResource.new(author).to_h }
          end

          def reviewer
            user = @verdict.decided_by_user_id && ::User.find_by(id: @verdict.decided_by_user_id)
            user && {id: user.id, name: user.name}
          end

          def match_decision
            id = @verdict.payload["match_decision_id"]
            decision = id && ::MatchDecision.find_by(id: id)
            decision && {id: decision.id, outcome: decision.outcome}
          end

          # Title and author live in the row's stored export line; the ISBN and Goodreads id come from the edition
          # the row resolved to, where the importer parsed them (the row has no such columns of its own).
          def source_rows
            ::Services::Books::RepairVerdicts::SourceRows.call(@verdict, limit: SOURCE_ROW_LIMIT).map do |row|
              edition = row.goodreads_edition
              {
                import_id: row.import.legacy_import_id, row_number: row.row_number,
                title: row.raw["Title"], author: row.raw["Author"],
                isbn13: edition&.isbn13, goodreads_book_id: edition&.goodreads_book_id
              }
            end
          end
        end
      end
    end
  end
end
