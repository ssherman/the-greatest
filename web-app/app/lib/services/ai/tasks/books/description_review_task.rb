module Services
  module Ai
    module Tasks
      module Books
        # Second opinion on a generated description, on the cheap role. Style
        # is also checked in code (Services::Books::DescriptionCheck); spoilers
        # can only be checked by a reader, so this is the reader.
        class DescriptionReviewTask < BaseTask
          VIOLATIONS = %w[em_dash semicolon names_title names_author marketing meta_narration banned_word not_but triad too_long too_short citation].freeze

          def initialize(parent:, description:, author_names: nil, provider: nil, model: nil)
            @description = description.to_s
            @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
            super(parent: parent, provider: provider, model: model)
          end

          private

          attr_reader :description

          def author_names
            @author_names.presence || parent.authors.map(&:name)
          end

          def task_provider = :openai

          def task_role = :fast

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM_MESSAGE
              You review one short book description against these rules and fix it if needed.

              Spoilers: the description may describe the premise, the setting, and the situation the book opens on. It must not reveal twists, deaths, endings, or how the central question resolves. For nonfiction it must not give away the conclusions. Set "spoilers" to true if it does, and say what in "spoiler_notes".

              Style violations, reported as codes in "style_violations" (empty list when clean):
              - em_dash: an em dash (—) or double hyphen (--)
              - semicolon: a semicolon
              - names_title: names the book's title
              - names_author: names the author
              - marketing: praise or sales language such as acclaimed, bestselling, masterpiece, unforgettable, must-read, awards, sales figures
              - meta_narration: "This novel", "This book", "Readers will", or similar
              - banned_word: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, "explores themes of"
              - not_but: a "not X but Y" or "isn't about X, it's about Y" construction
              - triad: an ornamental run of three adjectives or phrases
              - too_long: more than 110 words
              - too_short: fewer than 60 words
              - citation: a URL, bracketed reference, footnote, or citation

              If "spoilers" is true or "style_violations" is not empty, put a corrected version in "rewritten": one paragraph, 60 to 110 words, plain words, varied sentence length, no title or author name, same facts, nothing invented, spoilers removed. Otherwise set "rewritten" to null.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def user_prompt
            <<~PROMPT
              Book title: #{parent.title}
              Author(s): #{author_names.join(", ")}

              Description to review:
              #{description}
            PROMPT
          end

          def process_and_persist(provider_response)
            Services::Ai::Result.new(success: true, data: provider_response[:parsed], ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :spoilers, OpenAI::Boolean, doc: "true if the description reveals more than the premise"
            required :spoiler_notes, String, nil?: true, doc: "What was revealed, when spoilers is true"
            required :style_violations, OpenAI::ArrayOf[String], doc: "Violation codes from the list, empty when clean"
            required :rewritten, String, nil?: true, doc: "Corrected description, or null when nothing needed changing"
          end
        end
      end
    end
  end
end
