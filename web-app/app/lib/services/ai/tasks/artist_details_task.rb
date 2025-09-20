module Services
  module Ai
    module Tasks
      class ArtistDetailsTask < BaseTask
        private

        def task_provider = :openai

        def task_model = "gpt-5"

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
            - year_died: For individual people only - the year they died (if applicable)
            - year_formed: For bands only - the year the band was formed
            - year_disbanded: For bands only - the year the band disbanded (if applicable)
            
            Important: Only provide year_died for people, and only provide year_formed/year_disbanded for bands.
            Do not provide year_died for bands or year_formed/year_disbanded for people.
            
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
            # Start with basic fields that apply to all artists
            update_params = {
              description: data[:description],
              country: data[:country],
              kind: data[:kind]
            }

            # Add year fields based on artist type to avoid validation errors
            if data[:kind] == "person"
              # People can only have year_died (always set to clear existing values)
              update_params[:year_died] = data[:year_died]
              update_params[:year_formed] = nil
              update_params[:year_disbanded] = nil
            elsif data[:kind] == "band"
              # Bands can only have year_formed and year_disbanded (always set to clear existing values)
              update_params[:year_died] = nil
              update_params[:year_formed] = data[:year_formed]
              update_params[:year_disbanded] = data[:year_disbanded]
            end

            parent.update!(update_params)
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
          integer :year_died, required: false, description: "Year of death for people only"
          integer :year_formed, required: false, description: "Year formed for bands only"
          integer :year_disbanded, required: false, description: "Year disbanded for bands only"
        end
      end
    end
  end
end
