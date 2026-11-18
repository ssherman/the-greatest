# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # Books with a gap in their facts (first published year, original
      # language, a description), or whose paid research run was skipped, worked
      # by an agent. The agent answers in the shape the paid book-facts task
      # returns; the answer goes through RecordBookFacts, so the same rules
      # (fill blanks only, never refill what a human cleared) and the same
      # ledger row apply, with mode agent.
      class BookFacts < Services::EnrichmentQueue::Type
        extend BookScope

        VERSION = 1
        EVIDENCE_KEYS = %w[wikidata wikipedia worldcat goodreads].freeze
        FACT_KEYS = %w[first_published_year original_language word_count page_range subtitle alternate_titles description].freeze

        class << self
          def kind = "books.book_facts"

          def label = "Book facts"

          def version = VERSION

          def target_class = ::Books::Book

          def candidates(scope:)
            base_relation(scope: scope).where(has_author_sql).where(need_sql)
          end

          # The need conditions of candidates, for one book: a book with a running
          # run is still needed, a fill just does not offer it. Unlike candidates
          # it does not require an author link: the importer can enrich a book
          # before its links exist, and its deferred research must still be queued.
          def still_needed?(book)
            ::Books::Book.where(id: book.id).where(need_sql).exists?
          end

          def payload(book)
            dossier = Services::Books::Categorize::Dossier.build(book: book)
            {"book_id" => book.id, "record" => dossier.record, "missing" => missing(book),
             "evidence" => dossier.to_ledger.slice(*EVIDENCE_KEYS), "tried" => tried_facts(book)}
          end

          def reference
            {"answer_schema" => answer_schema}
          end

          def prompt_locals
            {fact_rules: Services::Ai::Tasks::Books::BookFactsTask::FACT_RULES,
             description_rules: Services::Ai::Tasks::Books::BookFactsTask::DESCRIPTION_RULES}
          end

          def answer_schema
            Services::Ai::Tasks::Books::BookFactsTask::ResponseSchema.to_json_schema.deep_stringify_keys
          end

          # A raise (a failed description review) propagates to the apply job,
          # which retries and then marks the row failed.
          def apply(request)
            row = Services::Books::RecordBookFacts.call(
              book: request.enrichable, facts: request.answer.deep_symbolize_keys, mode: :agent,
              citations: request.sources.uniq, provider: "agent", model: nil,
              hold_low_confidence: "low_confidence", strict_review: true,
              extra_facts: LedgerEntries.for_request(request, context: "agent")
            )
            Services::EnrichmentQueue::Type::Result.new(success?: true, data: {enrichment: row, outcome: row.outcome}, errors: [])
          end

          private

          def has_author_sql
            "EXISTS (SELECT 1 FROM #{::Books::BookAuthor.table_name} WHERE #{::Books::BookAuthor.table_name}.book_id = books_books.id)"
          end

          # A book lacks a description for this queue when it has no description
          # that is not deprecated AND no ai_generated one of any rank: the
          # applier keeps any AI description, even a deprecated one, so an
          # agent's description for such a book would never be written.
          def no_live_description_sql
            ActiveRecord::Base.sanitize_sql_array([
              "NOT EXISTS (SELECT 1 FROM descriptions WHERE descriptions.describable_type = 'Books::Book' " \
              "AND descriptions.describable_id = books_books.id AND (descriptions.rank <> ? OR descriptions.source = ?))",
              ::Description.ranks.fetch("deprecated"), ::Description.sources[:ai_generated]
            ])
          end

          def need_sql
            [
              "(books_books.first_published_year IS NULL AND #{Services::Books::HumanClearedFields.not_cleared_sql("first_published_year")})",
              "(books_books.original_language_id IS NULL AND #{Services::Books::HumanClearedFields.not_cleared_sql("original_language_id")})",
              no_live_description_sql,
              ResearchSkip.latest_sql(::Books::Book, kind)
            ].join(" OR ").then { "(#{it})" }
          end

          def missing(book)
            cleared = Services::Books::HumanClearedFields.for(book)
            missing = []
            missing << "first_published_year" if book.first_published_year.nil? && !cleared.include?("first_published_year")
            missing << "original_language" if book.original_language_id.nil? && !cleared.include?("original_language_id")
            # Same rule as no_live_description_sql.
            missing << "description" if book.descriptions.where.not(rank: :deprecated).or(book.descriptions.where(source: :ai_generated)).none?
            missing
          end

          # What the newest attempt that actually ran recorded; a skip tried nothing.
          def tried_facts(book)
            row = book.enrichments.where(kind: kind).where.not(outcome: :skipped).order(:id).last
            return nil unless row

            {"mode" => row.mode, "outcome" => row.outcome, "reason" => row.reason, "confidence" => row.confidence,
             "facts" => row.facts.slice(*FACT_KEYS)}
          end
        end
      end
    end
  end
end
