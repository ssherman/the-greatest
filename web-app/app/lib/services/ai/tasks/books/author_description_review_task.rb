module Services
  module Ai
    module Tasks
      module Books
        # Second opinion on a generated author description, on the cheap role
        # (spec §9). The book reviewer's spoiler judgment becomes two author
        # judgments: copied phrasing, against the Wikipedia lead the draft was
        # written from, and opening with the author's name. What the code
        # already found (Services::Books::DescriptionCheck) is passed in, so
        # the one rewrite fixes that too.
        class AuthorDescriptionReviewTask < BaseTask
          VIOLATIONS = %w[copied_phrasing names_author_at_start em_dash semicolon marketing meta_narration banned_word
            not_but triad too_long too_short citation].freeze
          CHECK_NOTES = {
            "copied" => "repeats eight or more consecutive words of the source text",
            "em_dash" => "contains an em dash or a spaced en dash (–)",
            "double_hyphen" => "contains a double hyphen",
            "url" => "contains a URL",
            "markdown_link" => "contains a markdown link",
            "too_short" => "is under 40 words",
            "too_long" => "is over 140 words"
          }.freeze

          def initialize(parent:, description:, source_text: nil, flagged: [], provider: nil, model: nil)
            @description = description.to_s
            @source_text = source_text.to_s.strip
            @flagged = Array(flagged)
            super(parent: parent, provider: provider, model: model)
          end

          private

          attr_reader :description, :source_text, :flagged

          def task_role = :fast

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM_MESSAGE
              You review one short description of an author against these rules and fix it if needed.

              Violations, reported as codes in "style_violations" (empty list when clean):
              - copied_phrasing: reuses a phrase or a sentence structure from the source text instead of saying it in new words
              - names_author_at_start: opens with the author's name
              - em_dash: an em dash (—), a spaced en dash ( – ), or a double hyphen (--)
              - semicolon: a semicolon
              - marketing: praise or sales language such as acclaimed, bestselling, masterpiece, beloved, celebrated, legendary, "one of the greatest", sales figures, or more than one award
              - meta_narration: "This author", "Readers will", or similar
              - banned_word: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, "explores themes of"
              - not_but: a "not X but Y" construction
              - triad: an ornamental run of three adjectives or phrases
              - too_long: more than 110 words
              - too_short: fewer than 60 words
              - citation: a URL, bracketed reference, footnote, or citation

              If "style_violations" is not empty, or the automated checks found a problem, put a corrected version in "rewritten": one paragraph, 60 to 110 words, plain words, varied sentence length, not opening with the author's name, in wording of your own rather than the source's, same facts, nothing invented. Otherwise set "rewritten" to null.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def user_prompt
            lines = ["Author: #{parent.name}"]
            if flagged.any?
              notes = flagged.map { |code| CHECK_NOTES.fetch(code, code) }
              lines << "Automated checks found that the description #{notes.join("; ")}."
            end
            lines << ""
            lines << "Description to review:"
            lines << description
            if source_text.present?
              lines << ""
              lines << "Source text the description was written from, for comparison only:"
              lines << source_text.first(AuthorFactsTask::LEAD_LIMIT)
            end
            lines.join("\n")
          end

          # A JSON round trip: the SDK's parsed schema object is a BaseModel,
          # whose #to_h is shallow.
          def process_and_persist(provider_response)
            parsed = provider_response[:parsed]
            data = parsed.nil? ? {} : JSON.parse(parsed.to_json, symbolize_names: true)
            Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :style_violations, OpenAI::ArrayOf[String], doc: "Violation codes from the list, empty when clean"
            required :rewritten, String, nil?: true, doc: "Corrected description, or null when nothing needed changing"
          end
        end
      end
    end
  end
end
