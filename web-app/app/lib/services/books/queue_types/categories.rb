# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # Books that still hold no real genre, worked by an agent. The agent
      # researches the book and answers in the shape the paid categories judge's
      # task returns; the answer goes through Categories::RecordAnswer, so the
      # same mapping, the same apply rules (caps, confidence gates, never
      # creating a category) and the same ledger row apply, with mode agent.
      # The agent adds and confirms; it never removes (rejudge is always false),
      # and it works even while the automatic judge is switched off.
      class Categories < Services::EnrichmentQueue::Type
        extend BookScope

        EVIDENCE_KEYS = %w[book_facts wikidata wikipedia worldcat goodreads].freeze
        CAP_KEYS = {"genres" => "genre", "subjects" => "subject", "locations" => "location"}.freeze

        class << self
          def kind = "books.categories"

          def label = "Book categories"

          def version = Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION

          def target_class = ::Books::Book

          def prompt_locals = {rules: Services::Ai::Tasks::Books::BookCategoriesTask::RULES}

          def candidates(scope:)
            base_relation(scope: scope).where(Services::Books::Categorize::Backfill.no_genre_sql)
          end

          # The same SQL as candidates' need condition, for one book: a book
          # with a running run is still needed, a fill just does not offer it.
          def still_needed?(book)
            ::Books::Book.where(id: book.id).where(Services::Books::Categorize::Backfill.no_genre_sql).exists?
          end

          def payload(book)
            dossier = Services::Books::Categorize::Dossier.build(book: book)
            {"book_id" => book.id, "record" => dossier.record,
             "evidence" => dossier.to_ledger.slice(*EVIDENCE_KEYS), "tried" => tried(book, kind)}
          end

          # Data only: the judgment rules live in the prompt the agent is given.
          def reference
            vocabulary = Services::Books::Categories::Judge.vocabulary
            {"answer_schema" => answer_schema,
             "genres" => vocabulary_entries(vocabulary, "genre"),
             "audiences" => vocabulary_entries(vocabulary, "audience"),
             "caps" => CAP_KEYS.transform_values { Services::Books::Categories::Apply::CAPS.fetch(it) }}
          end

          def answer_schema
            Services::Ai::Tasks::Books::BookCategoriesTask::ResponseSchema.to_json_schema.deep_stringify_keys
          end

          def paid_research? = true

          def paid_research_blocker
            "the categories judge is switched off (BOOKS_CATEGORIES_JUDGE_ENABLED)" unless Rails.application.config.x.ai.categories_judge_enabled
          end

          def research(request)
            result = Services::Books::Categories::Judge.call(book: request.enrichable, context: "queue", label: "queue", force_research: true)
            ledger_result(result.data[:enrichments].last)
          end

          def apply(request)
            book = request.enrichable
            row = Services::Books::Categories::RecordAnswer.call(
              book: book, dossier: Services::Books::Categorize::Dossier.build(book: book),
              answer: request.answer.deep_symbolize_keys, vocabulary: Services::Books::Categories::Judge.vocabulary,
              mode: :agent, context: "agent", label: "agent", rejudge: false,
              citations: request.sources.uniq, provider: "agent", model: nil,
              extra_facts: {"queue_request_id" => request.id}
            )
            return Services::EnrichmentQueue::Type::Result.new(success?: false, data: {enrichment: row}, errors: [row.error]) if row.failed?

            Services::EnrichmentQueue::Type::Result.new(success?: true, data: {enrichment: row, outcome: row.outcome}, errors: [])
          end

          private

          def vocabulary_entries(vocabulary, type)
            vocabulary.select { it.category_type == type }.sort_by(&:name).map do |category|
              {"id" => category.id, "name" => category.name, "definition" => category.description.to_s.squish.presence}
            end
          end
        end
      end
    end
  end
end
