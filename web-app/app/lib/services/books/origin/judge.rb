# frozen_string_literal: true

module Services
  module Books
    module Origin
      # Decides a book's national origin and applies it. Builds the evidence
      # dossier, tries the Wikidata shortcut, and otherwise asks the origin
      # task: from knowledge first, then by web search when the answer is weak
      # and the context's daily research budget allows. Writes one
      # books.origin ledger row per mode run.
      class Judge
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.origin"

        def self.call(book:, context:, label: nil, research_allowed: true, force: false, force_research: false)
          new(book: book, context: context, label: label, research_allowed: research_allowed,
            force: force, force_research: force_research).call
        end

        def initialize(book:, context:, label:, research_allowed:, force:, force_research:)
          @book = book
          @context = context
          @label = label
          @research_allowed = research_allowed
          @force = force
          @force_research = force_research
          @rows = []
        end

        def call
          if book.title.blank?
            rows << book.enrichments.create!(kind: KIND, mode: :knowledge, outcome: :skipped,
              reason: "missing_inputs", facts: base_facts("judge"))
            return result
          end

          @dossier = Categorize::Dossier.build(book: book)
          shortcut_country = Shortcut.call(dossier)

          if dossier.real_countries.any? && !force
            shortcut_country ? shortcut(shortcut_country) : has_origin
          elsif shortcut_country
            shortcut(shortcut_country)
          else
            judge
          end

          result
        end

        private

        attr_reader :book, :context, :label, :research_allowed, :force, :force_research, :rows, :dossier

        def has_origin
          rows << book.enrichments.create!(kind: KIND, mode: :knowledge, outcome: :nothing_to_apply,
            reason: "has_origin", facts: base_facts("has_origin"))
        end

        def shortcut(country)
          applied = apply(country.name, "high")
          answer = {"nationality" => country.name, "confidence" => "high", "reason" => "wikidata_agrees",
                    "recognized" => nil, "original_language" => nil}
          rows << book.enrichments.create!(
            kind: KIND, mode: :knowledge, outcome: applied.data[:applied] ? :applied : :nothing_to_apply,
            reason: applied.data[:reason], confidence: "high",
            facts: base_facts("shortcut").merge("answer" => answer, "origin" => applied.data.deep_stringify_keys)
          )
        end

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

          :knowledge
        end

        def past_cutoff?
          year = book.first_published_year
          year.present? && year >= Rails.application.config.x.ai.knowledge_cutoff_year
        end

        def research_permitted?
          return false unless research_allowed
          return true if force_research

          if context == "backfill"
            used = Enrichment.research.today.where(kind: KIND).where("facts->>'context' = 'backfill'").count
            used < Rails.application.config.x.ai.categorize_backfill_research_daily_cap
          else
            Enrichment.against_research_cap.count < Rails.application.config.x.ai.research_daily_cap
          end
        end

        # Returns [row, needs_research].
        def run(mode)
          chat = nil
          task_result = Services::Ai::Tasks::Books::BookOriginTask.new(parent: book, dossier: dossier, mode: mode).call
          chat = task_result.ai_chat
          return [failed_row(mode, task_result, task_result.error), false] unless task_result.success?

          answer = (task_result.data[:facts] || {}).to_h.symbolize_keys
          return [failed_row(mode, task_result, "empty response"), false] unless answer.key?(:nationality)

          citations = Array(task_result.data[:citations])
          confidence = confidence_for(answer[:confidence])
          recognized = answer[:recognized]
          unrecognized = recognized == false && !dossier.external?
          answer_facts = {"nationality" => answer[:nationality], "confidence" => answer[:confidence],
                          "reason" => answer[:reason], "recognized" => recognized,
                          "original_language" => answer[:original_language]}
          facts = base_facts("judge").merge("answer" => answer_facts)

          attributes = row_attributes(mode, chat).merge(recognized: recognized, confidence: confidence, citations: citations)
          if unrecognized
            attributes.merge!(outcome: :unrecognized, reason: "unrecognized", facts: facts)
          else
            applied = apply(answer[:nationality], answer[:confidence])
            attributes.merge!(outcome: applied.data[:applied] ? :applied : :nothing_to_apply,
              reason: applied.data[:reason], facts: facts.merge("origin" => applied.data.deep_stringify_keys))
          end
          needs = row_needs_research?(mode, confidence, unrecognized)
          [book.enrichments.create!(attributes), needs]
        rescue => e
          [book.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message,
            facts: base_facts("judge"))), false]
        end

        # Read before the row is written, so an error here is the failed row
        # and the mode run still leaves exactly one.
        def row_needs_research?(mode, confidence, unrecognized)
          mode == :knowledge && !real_country? && (confidence == "low" || unrecognized)
        end

        def apply(nationality, confidence)
          Apply.call(book: book, dossier: dossier, nationality: nationality, confidence: confidence)
        end

        # Read fresh: Apply may have written, or a concurrent job may have.
        def real_country?
          book.countries.reload.any? { !CountryLookup::PLACEHOLDERS.include?(it.name.downcase) }
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
          {"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, "context" => context,
           "label" => label, "path" => path, "dossier" => dossier&.to_ledger, "answer" => nil, "origin" => nil,
           "deferred_research" => false}
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
