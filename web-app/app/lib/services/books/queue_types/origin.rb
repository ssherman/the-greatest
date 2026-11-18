# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # Books that still have no real country, worked by an agent. The agent
      # researches the book and answers in the shape the paid origin judge's
      # task returns; the answer goes through Origin::RecordAnswer, so the same
      # rules (fill blanks only, confidence gates) and the same ledger row
      # apply, with mode agent.
      class Origin < Services::EnrichmentQueue::Type
        extend BookScope

        EVIDENCE_KEYS = %w[book_facts wikidata wikipedia worldcat goodreads].freeze

        class << self
          def kind = "books.origin"

          def label = "Book origin"

          def version = Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION

          def target_class = ::Books::Book

          def prompt_locals = {rules: Services::Ai::Tasks::Books::BookOriginTask::RULES}

          def candidates(scope:)
            base_relation(scope: scope).where(Services::Books::Categorize::Backfill.no_real_country_sql)
          end

          # The same SQL as candidates' need condition, for one book: a book
          # with a running run is still needed, a fill just does not offer it.
          def still_needed?(book)
            ::Books::Book.where(id: book.id).where(Services::Books::Categorize::Backfill.no_real_country_sql).exists?
          end

          def payload(book)
            dossier = Services::Books::Categorize::Dossier.build(book: book)
            {"book_id" => book.id, "record" => dossier.record,
             "evidence" => dossier.to_ledger.slice(*EVIDENCE_KEYS), "tried" => tried(book, kind)}
          end

          def reference
            {"answer_schema" => answer_schema}
          end

          def answer_schema
            Services::Ai::Tasks::Books::BookOriginTask::ResponseSchema.to_json_schema.deep_stringify_keys
          end

          def apply(request)
            book = request.enrichable
            row = Services::Books::Origin::RecordAnswer.call(
              book: book, dossier: Services::Books::Categorize::Dossier.build(book: book),
              answer: request.answer.symbolize_keys, mode: :agent, context: "agent", label: "agent",
              citations: request.sources.uniq, provider: "agent", model: nil,
              extra_facts: {"queue_request_id" => request.id}
            )
            return Services::EnrichmentQueue::Type::Result.new(success?: false, data: {enrichment: row}, errors: [row.error]) if row.failed?

            Services::EnrichmentQueue::Type::Result.new(success?: true, data: {enrichment: row, outcome: row.outcome}, errors: [])
          end
        end
      end
    end
  end
end
