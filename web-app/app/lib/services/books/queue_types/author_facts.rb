# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # Authors whose paid research run was skipped, worked by an agent. The
      # agent answers in the shape the paid author-facts task returns; the
      # answer goes through RecordAuthorFacts, so the same rules (fill blanks
      # only, review the description) and the same ledger row apply, with mode
      # agent. Only a research skip makes an author a candidate: a knowledge
      # pass that found nothing to ask about is not a gap an agent can fill.
      class AuthorFacts < Services::EnrichmentQueue::Type
        extend AuthorScope

        VERSION = 1
        FACT_KEYS = %w[birth_year death_year gender countries description].freeze
        BOOK_LIMIT = 10

        class << self
          def kind = "books.author_facts"

          def label = "Author facts"

          def version = VERSION

          def target_class = ::Books::Author

          def candidates(scope:)
            base_relation(scope: scope).where(ResearchSkip.latest_sql(::Books::Author, kind))
          end

          # The same ledger condition as candidates, for one author: a running
          # run leaves the author needed, a fill just does not offer it.
          def still_needed?(author)
            return false if author.exclude_from_rankings

            ::Books::Author.where(id: author.id).where(ResearchSkip.latest_sql(::Books::Author, kind)).exists?
          end

          def payload(author)
            {"author_id" => author.id, "record" => record(author), "tried" => tried_facts(author)}
          end

          def reference
            {"answer_schema" => answer_schema}
          end

          def answer_schema
            Services::Ai::Tasks::Books::AuthorFactsTask::ResponseSchema.to_json_schema.deep_stringify_keys
          end

          # A raise (a failed description review) propagates to the apply job,
          # which retries and then marks the row failed.
          def apply(request)
            author = request.enrichable
            row = Services::Books::Authors::RecordAuthorFacts.call(
              author: author, records: Services::Books::Authors::MatchedRecords.new(author),
              facts: request.answer.deep_symbolize_keys, mode: :agent, citations: request.sources.uniq,
              provider: "agent", model: nil, hold_low_confidence: "low_confidence", strict_review: true,
              extra_facts: LedgerEntries.for_request(request, context: "agent")
            )
            Services::EnrichmentQueue::Type::Result.new(success?: true, data: {enrichment: row, outcome: row.outcome}, errors: [])
          end

          private

          def record(author)
            books = Services::Books::Authors::AuthorProfile.new(author).ranked_books(BOOK_LIMIT)
            {"name" => author.name, "alternate_names" => Array(author.alternate_names).first(10),
             "birth_year" => author.birth_year, "death_year" => author.death_year, "gender" => author.gender,
             "countries" => author.countries.map(&:name).sort,
             "books" => books.map { |title, year| {"title" => title, "first_published_year" => year} },
             "has_description" => author.descriptions.where.not(rank: :deprecated).exists?}
          end

          # What the newest attempt that actually ran recorded; a skip tried nothing.
          def tried_facts(author)
            row = author.enrichments.where(kind: kind).where.not(outcome: :skipped).order(:id).last
            return nil unless row

            {"mode" => row.mode, "outcome" => row.outcome, "confidence" => row.confidence,
             "facts" => row.facts.slice(*FACT_KEYS)}
          end
        end
      end
    end
  end
end
