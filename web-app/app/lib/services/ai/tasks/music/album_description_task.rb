module Services
  module Ai
    module Tasks
      module Music
        class AlbumDescriptionTask < BaseTask
          private

          def task_provider = :openai

          def task_model = "gpt-5-mini"

          def system_message
            <<~SYSTEM_MESSAGE
              You are a cautious music copywriter. Write brief, factual descriptions of albums you know well. Include basic information about the musical style, significance, or notable characteristics, but avoid specific claims about awards, chart positions, sales figures, or detailed critical reception unless you're completely certain.

              If you don't know the album well enough to write a meaningful description beyond just restating the provided metadata, set "abstained" to true and explain why.

              Style: one paragraph, concise and readable, no em dashes (—) or double hyphens (--), no emojis, no lists, no marketing language. Prefer plain punctuation.
              Output only the specified JSON object.
            SYSTEM_MESSAGE
          end

          def user_prompt
            <<~PROMPT.squish
              I need a description for the album "#{parent.title}" by #{parent.artists.map(&:name).join(", ")}#{" (#{parent.release_year})" if parent.release_year}.

              #{"Genre context: #{parent.categories.map(&:name).join(", ")}" if parent.categories.any?}

              Please provide a brief description of this album. If you know this album well, write about its musical style, sound, or significance. If you don't know this specific album well enough to write a meaningful description, set "abstained" to true and explain why.

              Respond with valid JSON matching the schema.
            PROMPT
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            # provider_response[:parsed] is validated data from schema
            data = provider_response[:parsed]

            # Only update the album if the AI provided a description
            if data[:description].present? && !data[:abstained]
              parent.update!(description: data[:description])
            end

            Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
          end

          # Internal schema class
          class ResponseSchema < OpenAI::BaseModel
            required :description, String, nil?: true, doc: "Brief description of the album using only provided context"
            required :abstained, OpenAI::Boolean, doc: "Whether the AI abstained from providing a description"
            required :abstain_reason, String, nil?: true, doc: "Reason for abstaining if abstained is true"
          end
        end
      end
    end
  end
end
