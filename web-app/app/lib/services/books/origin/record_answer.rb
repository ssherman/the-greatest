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

        # accept_medium is handed to Origin::Apply (see there); the agent queue sets it.
        def self.call(book:, dossier:, answer:, mode:, context:, label:, citations: [], ai_chat: nil, provider: nil,
          model: nil, extra_facts: {}, accept_medium: false)
          new(book: book, dossier: dossier, answer: answer, mode: mode, context: context, label: label,
            citations: citations, ai_chat: ai_chat, provider: provider, model: model, extra_facts: extra_facts,
            accept_medium: accept_medium).call
        end

        # The facts every books.origin row starts from; callers merge their own
        # keys over it. The one definition, shared with Judge's other rows.
        def self.base_facts(context:, label:, dossier:, path:)
          {"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, "context" => context,
           "label" => label, "path" => path, "dossier" => dossier&.to_ledger, "answer" => nil, "origin" => nil,
           "deferred_research" => false}
        end

        def initialize(book:, dossier:, answer:, mode:, context:, label:, citations:, ai_chat:, provider:, model:, extra_facts:,
          accept_medium: false)
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
          @accept_medium = accept_medium
        end

        def call
          recognized = answer[:recognized]
          unrecognized = recognized == false && !dossier.external? && !dossier.research_backed?
          answer_facts = {"nationality" => answer[:nationality], "confidence" => answer[:confidence],
                          "reason" => answer[:reason], "recognized" => recognized,
                          "original_language" => answer[:original_language]}
          facts = self.class.base_facts(context: context, label: label, dossier: dossier, path: "judge").merge("answer" => answer_facts)

          attributes = {kind: KIND, mode: mode, ai_chat: ai_chat, provider: provider, model: model,
                        recognized: recognized, confidence: confidence_for(answer[:confidence]), citations: citations}
          if unrecognized
            attributes.merge!(outcome: :unrecognized, reason: "unrecognized", facts: facts.merge(extra_facts))
          else
            applied = Apply.call(book: book, dossier: dossier, nationality: answer[:nationality], confidence: answer[:confidence],
              accept_medium: @accept_medium)
            attributes.merge!(outcome: applied.data[:applied] ? :applied : :nothing_to_apply,
              reason: applied.data[:reason],
              facts: facts.merge("origin" => applied.data.deep_stringify_keys).merge(extra_facts))
          end
          book.enrichments.create!(attributes)
        end

        private

        attr_reader :book, :dossier, :answer, :mode, :context, :label, :citations, :ai_chat, :provider, :model, :extra_facts

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          Enrichment.confidences.key?(normalized) ? normalized : nil
        end
      end
    end
  end
end
