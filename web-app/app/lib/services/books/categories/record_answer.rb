# frozen_string_literal: true

module Services
  module Books
    module Categories
      # The "answer in, ledger row out" half of a books.categories judgment: takes
      # an answer in the shape BookCategoriesTask returns (Symbol keys), decides
      # whether it is an unrecognized book, maps it onto existing categories
      # (Mapper), applies it by the fixed rules (Apply) and writes the one
      # books.categories ledger row. Shared by the paid judge and the agent queue,
      # so both write rows of the same shape.
      #
      # A raise before anything is committed propagates: the judge turns it into
      # a failed row, the queue's apply job retries it. A raise after the mapping
      # was built is rescued here and written as a failed row that still carries
      # the "mapping" and "apply" facts: once Apply has committed removals, that
      # row is what restore_removals reads to find them.
      class RecordAnswer
        KIND = "books.categories"

        def self.call(book:, dossier:, answer:, vocabulary:, mode:, context:, label:, rejudge:, citations: [],
          ai_chat: nil, provider: nil, model: nil, extra_facts: {})
          new(book: book, dossier: dossier, answer: answer, vocabulary: vocabulary, mode: mode, context: context,
            label: label, rejudge: rejudge, citations: citations, ai_chat: ai_chat, provider: provider, model: model,
            extra_facts: extra_facts).call
        end

        # The facts every books.categories row starts from; callers merge their
        # own keys over it. The one definition, shared with Judge's other rows.
        def self.base_facts(context:, label:, dossier:, path:)
          {"prompt_version" => Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION, "context" => context,
           "label" => label, "path" => path, "dossier" => dossier&.to_ledger, "answer" => nil, "mapping" => nil,
           "apply" => nil, "choice_chat_id" => nil, "parent_choice_chat_id" => nil, "deferred_research" => false}
        end

        def initialize(book:, dossier:, answer:, vocabulary:, mode:, context:, label:, rejudge:, citations:, ai_chat:,
          provider:, model:, extra_facts:)
          @book = book
          @dossier = dossier
          @answer = normalize_confidences(answer.deep_symbolize_keys)
          @vocabulary = vocabulary
          @mode = mode
          @context = context
          @label = label
          @rejudge = rejudge
          @citations = citations
          @ai_chat = ai_chat
          @provider = provider
          @model = model
          @extra_facts = extra_facts
          @committed = {}
        end

        def call
          recognized = answer[:recognized]
          unrecognized = recognized == false && !dossier.external? && !dossier.research_backed?
          facts = base_facts.merge("answer" => answer.deep_stringify_keys)
          attributes = row_attributes.merge(recognized: recognized, confidence: confidence_for(answer[:confidence]),
            citations: citations)

          if unrecognized
            attributes.merge!(outcome: :unrecognized, reason: "unrecognized", facts: facts.merge(extra_facts))
          else
            mapped = Mapper.call(book: book, answer: answer, vocabulary: vocabulary)
            return failed_row(Array(mapped.errors).join("; "), facts) unless mapped.success?

            # Built before Apply and kept for the rescue below: once Apply has committed removals the
            # failed row must still carry them, or restore_removals cannot find them.
            committed["mapping"] = mapping_facts(mapped.data)
            applied = Apply.call(book: book, dossier: dossier, answer: answer, resolved: mapped.data[:resolved],
              rejudge: rejudge, unmatched: mapped.data[:unmatched])
            committed["apply"] = applied.data.deep_stringify_keys
            changed = applied.data.values_at(:added, :confirmed, :removed).any?(&:present?) || applied.data.dig(:type, :applied) == true
            attributes.merge!(outcome: changed ? :applied : :nothing_to_apply, reason: changed ? "applied" : "nothing_applied",
              facts: facts.merge(committed).merge(
                "choice_chat_id" => mapped.data[:ai_chat]&.id,
                "parent_choice_chat_id" => mapped.data[:parent_ai_chat]&.id
              ).merge(extra_facts))
          end
          book.enrichments.create!(attributes)
        rescue => e
          raise if committed.empty?

          failed_row(e.message, base_facts.merge(committed))
        end

        private

        attr_reader :book, :dossier, :answer, :vocabulary, :mode, :context, :label, :rejudge, :citations, :ai_chat,
          :provider, :model, :extra_facts, :committed

        def base_facts
          self.class.base_facts(context: context, label: label, dossier: dossier, path: "judge")
        end

        def row_attributes
          {kind: KIND, mode: mode, ai_chat: ai_chat, provider: provider, model: model}
        end

        def failed_row(error, facts)
          book.enrichments.create!(row_attributes.merge(outcome: :failed, error: error, facts: facts.merge(extra_facts)))
        end

        # Confidence values are compared as lowercase strings downstream.
        def normalize_confidences(answer)
          clean = ->(value) { value.is_a?(String) ? value.strip.downcase : value }
          answer = answer.merge(confidence: clean.call(answer[:confidence]))
          answer[:book_type] = answer[:book_type].merge(confidence: clean.call(answer[:book_type][:confidence])) if answer[:book_type].is_a?(Hash)
          answer[:audience] = answer[:audience].merge(confidence: clean.call(answer[:audience][:confidence])) if answer[:audience].is_a?(Hash)
          %i[genres subjects locations].each do |key|
            next unless answer[key].is_a?(Array)

            answer[key] = answer[key].map { |entry| entry.is_a?(Hash) ? entry.merge(confidence: clean.call(entry[:confidence])) : entry }
          end
          answer
        end

        def mapping_facts(data)
          {"resolved" => data[:resolved].map { |entry|
            {"id" => entry[:category].id, "name" => entry[:category].name, "type" => entry[:type], "via" => entry[:via],
             "confidence" => entry[:confidence], "originals" => Array(entry[:originals])}
          }, "unmatched" => data[:unmatched].map(&:deep_stringify_keys)}
        end

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          Enrichment.confidences.key?(normalized) ? normalized : nil
        end
      end
    end
  end
end
