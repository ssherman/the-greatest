module Services
  module Ai
    module Tasks
      module Books
        # The Goodreads re-import's second look before it creates a book: the finder searches an English catalog, so
        # a translated edition (Der talentierte Mr. Ripley, Тріснуло дзеркало) finds nothing and would become a
        # non-English duplicate of a book we hold. This asks for the title of the work's English edition, which the
        # caller searches with again. The title is only a search term: the same-work check still decides the match.
        class EnglishTitleTask < BaseTask
          VALID_CONFIDENCE = %w[high medium low].freeze
          USABLE_CONFIDENCE = %w[high medium].freeze

          attr_reader :facts

          def initialize(facts:, parent: nil, provider: nil, model: nil)
            @facts = facts
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :fast

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You help match a reader's book to an English-language book catalog. A reader's Goodreads export names one edition. If its title is not in English, give the title of the same work's English-language edition.
              - A translation of a work: give the title the work is published under in English (for example "Der talentierte Mr. Ripley" by Patricia Highsmith is "The Talented Mr. Ripley").
              - A work first written in another language: give its usual English title, if it has been published in English.
              - Keep the volume, part or issue: a translated volume 2 is the English volume 2, not the series.
              - Give the title only, without the series in parentheses.
              Use a null english_title when the title is already English, or when you do not know an English edition. Never invent a title.
              Give confidence: "high" when you are sure the English edition has that title, "medium" when it is likely, "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Goodreads edition:", "Title: #{facts.full_title}", "Authors: #{Array(facts.author_names).join("; ")}"]
            lines << "Original publication year: #{facts.year}" if facts.year.present?
            lines << "Series: #{facts.series_name}#{" ##{facts.series_number}" if facts.series_number.present?}" if facts.series_name.present?
            lines << ""
            lines << "Answer with the English edition's title (or null), a confidence and a short reason."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            confidence = data[:confidence]
            return failure("Unexpected confidence value: #{confidence.inspect}") unless VALID_CONFIDENCE.include?(confidence)

            Services::Ai::Result.new(success: true, data: {title: usable_title(data[:english_title], confidence), confidence: confidence,
                                                           reason: data[:reason].to_s}, ai_chat: chat)
          end

          # Only a title worth searching with: a likely one that differs from what the edition already says.
          def usable_title(answer, confidence)
            title = answer.to_s.squish
            return nil if title.empty? || !USABLE_CONFIDENCE.include?(confidence)
            return nil if [facts.full_title, facts.title].compact.any? { |own| own.to_s.squish.casecmp?(title) }

            title
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :english_title, String, nil?: true, doc: "The English edition's title, or null"
            required :confidence, String, doc: "Exactly one of: high, medium, low"
            required :reason, String, doc: "One or two sentences"
          end
        end
      end
    end
  end
end
