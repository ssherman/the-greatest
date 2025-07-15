module Services
  module Ai
    module Tasks
      class ArtistDetailsTask < BaseTask
        private

        def task_provider = :openai

        def task_model = "gpt-4o"

        def system_message
          <<~SYSTEM_MESSAGE
            You are a music expert who can extract detailed information about musical artists.
            You can distinguish between individual people and bands, and provide accurate biographical and career information.
            If you don't know or are unsure about an artist, it's better to indicate that than to guess.
          SYSTEM_MESSAGE
        end

        def user_prompt
          <<~PROMPT.squish
            I need detailed information about the artist "#{parent.name}".
            
            Please provide the following information if you know this artist:
            - description: A brief description of the artist and their style/genre
            - country: The country they are from (as ISO-3166 alpha-2 country code, e.g., "US", "GB", "DE")
            - kind: Whether this is a "person" (individual artist) or "band" (group)
            
            If you don't know this artist or are unsure, set "artist_known" to false.
            Only provide the other details if you are confident about the artist.
            
            Respond with valid JSON matching the schema.
          PROMPT
        end

        def response_format = {type: "json_object"}

        def response_schema
          ResponseSchema
        end

        def process_and_persist(provider_response)
          # provider_response[:parsed] is validated data from RubyLLM schema
          data = provider_response[:parsed]

          # Only update the artist if the AI knows about them
          if data[:artist_known]
            parent.update!(
              description: data[:description],
              country: data[:country],
              kind: data[:kind]
            )
          end

          Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
        end

        # Internal schema class
        class ResponseSchema < RubyLLM::Schema
          def self.name
            "ArtistDetails"
          end

          boolean :artist_known, required: true, description: "Whether the AI knows this artist"
          string :description, required: false, description: "Brief description of the artist and their style/genre"
          string :country, required: false, description: "ISO-3166 alpha-2 country code"
          string :kind, required: false, enum: ["person", "band"], description: "Whether this is a person or band"
        end
      end
    end
  end
end
