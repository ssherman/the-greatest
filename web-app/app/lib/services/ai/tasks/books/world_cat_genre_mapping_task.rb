# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Maps WorldCat genre terms onto our curated genre list, once
        # (docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md, "Vocabulary mapping").
        # Parentless: the result is a data file, not a record.
        class WorldCatGenreMappingTask < BaseTask
          VERDICTS = %w[genre subject drop].freeze
          REASONS = %w[format language_of_material not_a_genre too_specific].freeze

          attr_reader :terms, :genres

          def initialize(terms:, genres:, parent: nil, provider: nil, model: nil)
            @terms = terms
            @genres = genres
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :standard

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You classify library catalogue genre/form terms for a book website.
              The terms come from WorldCat records and may be in any language, with
              variant spellings, trailing punctuation, or BISAC-style headings.

              For each term give exactly one verdict:
              - "genre": the term describes what kind of book it is and fits one of the
                site's genres. Set "genre" to that genre's name, copied exactly from the list.
                Fold variants and translations onto the same genre ("Biographies",
                "Biografías" and "Biography" all map to the genre named Biography).
              - "subject": the term says what the book is ABOUT rather than what it is,
                and no genre fits. Set "subject" to a short canonical English phrase.
              - "drop": the term describes the physical item or its language ("Large type
                books", "Electronic books", "Spanish language materials", "Audiobooks",
                "Translations"), is not a genre or subject at all, or is too specific to
                be useful. Set "reason" to one of: format, language_of_material,
                not_a_genre, too_specific.

              Always set "language" to the ISO 639-1 code of the term's language.
              Never invent a genre: a "genre" verdict must name one from the list.
              Answer with JSON matching the schema, one verdict per term, in order.
            SYSTEM
          end

          def user_prompt
            lines = ["Site genres (use these names exactly):"]
            genres.each { |name| lines << "- #{name}" }
            lines << ""
            lines << "Terms to classify (uses = WorldCat records carrying the term; books = our books):"
            terms.each_with_index do |(term, uses, books), index|
              lines << "#{index + 1}. #{term} (#{uses} uses on #{books} books)"
            end
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def process_and_persist(provider_response)
            asked = terms.map(&:first)
            raw = Array(provider_response[:parsed][:verdicts]).map { |v| normalize(v) }
            verdicts = raw.select { |v| asked.include?(v[:term]) }.uniq { |v| v[:term] }

            missing = asked - verdicts.map { |v| v[:term] }
            return failure("No verdict for: #{missing.join(", ")}") if missing.any?

            bad = verdicts.reject { |v| VERDICTS.include?(v[:verdict]) }
            return failure("Unknown verdict #{bad.first[:verdict].inspect} for #{bad.first[:term].inspect}") if bad.any?

            wrong_genre = verdicts.select { |v| v[:verdict] == "genre" && !genres.include?(v[:genre]) }
            return failure("#{wrong_genre.first[:genre].inspect} is not a site genre (term #{wrong_genre.first[:term].inspect})") if wrong_genre.any?

            no_subject = verdicts.select { |v| v[:verdict] == "subject" && v[:subject].blank? }
            return failure("Subject verdict without a phrase for #{no_subject.first[:term].inspect}") if no_subject.any?

            bad_reason = verdicts.select { |v| v[:verdict] == "drop" && !REASONS.include?(v[:reason]) }
            return failure("Unknown drop reason #{bad_reason.first[:reason].inspect} for #{bad_reason.first[:term].inspect}") if bad_reason.any?

            Services::Ai::Result.new(success: true, data: {verdicts: verdicts}, ai_chat: chat)
          end

          def normalize(verdict)
            hash = verdict.respond_to?(:to_h) ? verdict.to_h : verdict
            hash = JSON.parse(hash.to_json, symbolize_names: true)
            {term: hash[:term].to_s, verdict: hash[:verdict].to_s, genre: hash[:genre].presence,
             subject: hash[:subject].presence, language: hash[:language].presence, reason: hash[:reason].presence}
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Verdict < OpenAI::BaseModel
            required :term, String, doc: "The term exactly as given"
            required :verdict, String, doc: "genre, subject or drop"
            required :genre, String, nil?: true, doc: "For genre: a site genre name, exactly as listed"
            required :subject, String, nil?: true, doc: "For subject: a short canonical English phrase"
            required :language, String, doc: "ISO 639-1 code of the term's language"
            required :reason, String, nil?: true, doc: "For drop: format, language_of_material, not_a_genre or too_specific"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :verdicts, OpenAI::ArrayOf[Verdict], doc: "One per term, in the order given"
          end
        end
      end
    end
  end
end
