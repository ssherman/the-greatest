# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Decides a book's genres, audience, subjects, locations and book type and
      # applies them. Builds the evidence dossier, asks the categories task from
      # knowledge first, then by web search when the book was not recognized (or
      # is past the model's knowledge cutoff) and the context's daily research
      # budget allows. Writes one books.categories ledger row per mode run.
      class Judge
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.categories"
        VOCABULARY_TYPES = %w[genre audience].freeze

        def self.call(book:, context:, label: nil, research_allowed: true, force_research: false)
          new(book: book, context: context, label: label, research_allowed: research_allowed,
            force_research: force_research).call
        end

        def initialize(book:, context:, label:, research_allowed:, force_research:)
          @book = book
          @context = context
          @label = label
          @research_allowed = research_allowed
          @force_research = force_research
          @rows = []
        end

        def call
          if book.title.blank?
            rows << book.enrichments.create!(kind: KIND, mode: :knowledge, outcome: :skipped,
              reason: "missing_inputs", facts: base_facts("judge"))
            return result
          end

          # Read before any row is written: judge writes one.
          @owes_research = previously_deferred?
          @dossier = Categorize::Dossier.build(book: book)
          @vocabulary = ::Books::Category.active.where(category_type: VOCABULARY_TYPES)
            .where.not(name: ::Books::Book::BOOK_TYPE_CATEGORY_NAMES).order(:category_type, :name).to_a
          judge
          result
        end

        private

        attr_reader :owes_research, :book, :context, :label, :research_allowed, :force_research, :rows, :dossier, :vocabulary

        def judge
          first_mode = first_mode()
          # A past-cutoff book that cannot be researched is judged from
          # knowledge and its research is owed. Not when the caller already
          # researched in this run (research_allowed false).
          deferred = first_mode == :knowledge && past_cutoff? && research_allowed
          row, needs_research = run(first_mode)
          rows << row
          return if row.failed?

          if first_mode == :knowledge && needs_research && research_allowed
            if research_permitted?
              rows << run(:research).first
            else
              deferred = true
            end
          end
          row.update!(facts: row.facts.merge("deferred_research" => true)) if deferred
        end

        def first_mode
          return :research if force_research
          return :research if past_cutoff? && research_permitted?
          # Its knowledge call already ran and deferred this book's research.
          return :research if owes_research && research_permitted?

          :knowledge
        end

        # The book's latest books.categories row, from the current prompt
        # version, owes research. Read before this call writes any row.
        def previously_deferred?
          latest = book.enrichments.where(kind: KIND).order(:id).last
          latest.present? && latest.facts["deferred_research"] == true &&
            latest.facts["prompt_version"] == Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION
        end

        def past_cutoff?
          year = book.first_published_year
          year.present? && year >= Rails.application.config.x.ai.knowledge_cutoff_year
        end

        def research_permitted?
          return false unless research_allowed
          return true if force_research

          Categorize::ResearchBudget.permitted?(context: context)
        end

        # Returns [row, needs_research].
        def run(mode)
          chat = nil
          task_result = Services::Ai::Tasks::Books::BookCategoriesTask.new(parent: book, dossier: dossier,
            vocabulary: vocabulary, mode: mode).call
          chat = task_result.ai_chat
          return [failed_row(mode, task_result, task_result.error), false] unless task_result.success?

          answer = (task_result.data[:facts] || {}).to_h.deep_symbolize_keys
          return [failed_row(mode, task_result, "empty response"), false] if answer.empty?

          recognized = answer[:recognized]
          unrecognized = recognized == false && !dossier.external? && !dossier.research_backed?
          facts = base_facts("judge").merge("answer" => answer.deep_stringify_keys)
          attributes = row_attributes(mode, chat).merge(recognized: recognized, confidence: confidence_for(answer[:confidence]),
            citations: Array(task_result.data[:citations]))

          if unrecognized
            attributes.merge!(outcome: :unrecognized, reason: "unrecognized", facts: facts)
          else
            mapped = Mapper.call(book: book, answer: answer, vocabulary: vocabulary)
            unless mapped.success?
              return [book.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed,
                error: Array(mapped.errors).join("; "), facts: facts)), false]
            end

            applied = Apply.call(book: book, dossier: dossier, answer: answer, resolved: mapped.data[:resolved],
              rejudge: context != "import")
            changed = applied.data.values_at(:added, :confirmed, :removed).any?(&:present?) || applied.data.dig(:type, :applied) == true
            attributes.merge!(outcome: changed ? :applied : :nothing_to_apply, reason: changed ? "applied" : "nothing_applied",
              facts: facts.merge("mapping" => mapping_facts(mapped.data), "apply" => applied.data.deep_stringify_keys,
                "choice_chat_id" => mapped.data[:ai_chat]&.id))
          end
          [book.enrichments.create!(attributes), mode == :knowledge && unrecognized]
        rescue => e
          [book.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message,
            facts: base_facts("judge"))), false]
        end

        def mapping_facts(data)
          {"resolved" => data[:resolved].map { |entry|
            {"id" => entry[:category].id, "name" => entry[:category].name, "type" => entry[:type], "via" => entry[:via],
             "confidence" => entry[:confidence]}
          }, "unmatched" => data[:unmatched].map(&:deep_stringify_keys)}
        end

        def failed_row(mode, task_result, error)
          role = Services::Ai::Roles.resolve((mode == :research) ? :research : :standard)
          book.enrichments.create!(
            kind: KIND, mode: mode, outcome: :failed, error: error,
            provider: role.provider.to_s, model: role.model, ai_chat: task_result.ai_chat,
            facts: base_facts("judge")
          )
        end

        def row_attributes(mode, chat)
          {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
        end

        def base_facts(path)
          {"prompt_version" => Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION, "context" => context,
           "label" => label, "path" => path, "dossier" => dossier&.to_ledger, "answer" => nil, "mapping" => nil,
           "apply" => nil, "choice_chat_id" => nil, "deferred_research" => false}
        end

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          Enrichment.confidences.key?(normalized) ? normalized : nil
        end

        def result
          failures = rows.select(&:failed?)
          Result.new(success?: failures.empty?,
            data: {enrichments: rows, applied: rows.any?(&:applied?)},
            errors: failures.map(&:error))
        end
      end
    end
  end
end
