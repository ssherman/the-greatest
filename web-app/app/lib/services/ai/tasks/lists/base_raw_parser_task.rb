# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        class BaseRawParserTask < Services::Ai::Tasks::BaseTask
          # Override BaseTask initializer to accept optional content parameter.
          # When content: is provided (for batch processing), uses that content
          # instead of parent.simplified_html and skips parent.update! in persist.
          def initialize(parent:, content: nil, provider: nil, model: nil)
            @provided_content = content
            super(parent: parent, provider: provider, model: model)
          end

          private

          def chat_type = :analysis

          def task_provider = :openai  # Use OpenAI for JSON schema support

          def task_model = "gpt-5-mini"

          def temperature = 1.0  # GPT-5 does not support temperature

          def system_message
            <<~SYSTEM_MESSAGE
              You are a parser that extracts #{media_type} information from HTML lists into structured format.

              Your ONLY task is to extract the following information for each #{media_type.singularize} in the provided HTML:
              #{extraction_fields.map { |field| "- #{field}" }.join("\n")}

              #{media_specific_instructions}

              Do not perform any lookups, research, or additional processing beyond simple extraction.
              Focus ONLY on extracting the data that is explicitly present in the HTML.
            SYSTEM_MESSAGE
          end

          def user_prompt
            <<~PROMPT
              This HTML is from a #{media_type} list titled "#{parent.name}" from #{list_source_context} and we want to extract the names of the #{media_type} from it.

              Extract #{media_type} information from the following HTML. Focus ONLY on extracting the data without any additional processing:

              ```html
              #{content_to_parse}
              ```

              #{extraction_examples}

              Return ONLY the structured data as a JSON object with a '#{media_type}' array.

              IMPORTANT:
              - Every entry MUST include all required fields, even if some values are null
              - Do NOT perform any research or lookups
              - Do NOT add any information that isn't explicitly in the HTML
              - Work quickly and efficiently - focus only on extraction
            PROMPT
          end

          def content_to_parse
            @provided_content || parent.simplified_html
          end

          def response_format = {type: "json_object"}

          def process_and_persist(provider_response)
            data = JSON.parse(provider_response[:content], symbolize_names: true)
            # Only update parent.items_json in normal mode (not batch mode)
            parent.update!(items_json: data) unless @provided_content
            create_result(success: true, data: data, ai_chat: chat)
          end

          # Abstract methods - override in subclasses
          def media_type
            raise NotImplementedError, "Subclasses must define media_type"
          end

          def extraction_fields
            raise NotImplementedError, "Subclasses must define extraction_fields"
          end

          def media_specific_instructions
            ""
          end

          def extraction_examples
            ""
          end

          def list_source_context
            parent.source.presence || parent.url.presence || "an unknown source"
          end
        end
      end
    end
  end
end
