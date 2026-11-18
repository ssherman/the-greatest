# frozen_string_literal: true

module Services
  module Books
    module Origin
      # The "answer in, ledger row out" half of a books.origin judgment: takes
      # an answer in the shape the origin task returns (Symbol keys), decides
      # whether it is an unrecognized book, hands it to Origin::Apply (which
      # holds the rules: fill blanks only, confidence gates) and writes the one
      # books.origin ledger row. Shared by the paid judge and the agent queue,
      # so both write rows of the same shape. A raise propagates: the judge
      # turns it into a failed row, the queue's apply job retries it.
      class RecordAnswer
        KIND = "books.origin"

        def self.call(book:, dossier:, answer:, mode:, context:, label:, citations: [], ai_chat: nil, provider: nil,
          model: nil, extra_facts: {})
          new(book: book, dossier: dossier, answer: answer, mode: mode, context: context, label: label,
            citations: citations, ai_chat: ai_chat, provider: provider, model: model, extra_facts: extra_facts).call
        end

        def initialize(book:, dossier:, answer:, mode:, context:, label:, citations:, ai_chat:, provider:, model:, extra_facts:)
          @book = book
          @dossier = dossier
          @answer = answer
          @mode = mode
          @context = context
          @label = label
          @citations = citations
          @ai_chat = ai_chat
          @provider = provider
          @model = model
          @extra_facts = extra_facts
        end

        def call
          recognized = answer[:recognized]
          unrecognized = recognized == false && !dossier.external? && !dossier.research_backed?
          answer_facts = {"nationality" => answer[:nationality], "confidence" => answer[:confidence],
                          "reason" => answer[:reason], "recognized" => recognized,
                          "original_language" => answer[:original_language]}
          facts = base_facts.merge("answer" => answer_facts)

          attributes = {kind: KIND, mode: mode, ai_chat: ai_chat, provider: provider, model: model,
                        recognized: recognized, confidence: confidence_for(answer[:confidence]), citations: citations}
          if unrecognized
            attributes.merge!(outcome: :unrecognized, reason: "unrecognized", facts: facts.merge(extra_facts))
          else
            applied = Apply.call(book: book, dossier: dossier, nationality: answer[:nationality], confidence: answer[:confidence])
            attributes.merge!(outcome: applied.data[:applied] ? :applied : :nothing_to_apply,
              reason: applied.data[:reason],
              facts: facts.merge("origin" => applied.data.deep_stringify_keys).merge(extra_facts))
          end
          book.enrichments.create!(attributes)
        end

        private

        attr_reader :book, :dossier, :answer, :mode, :context, :label, :citations, :ai_chat, :provider, :model, :extra_facts

        def base_facts
          {"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, "context" => context,
           "label" => label, "path" => "judge", "dossier" => dossier&.to_ledger, "answer" => nil, "origin" => nil,
           "deferred_research" => false}
        end

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          Enrichment.confidences.key?(normalized) ? normalized : nil
        end
      end
    end
  end
end
