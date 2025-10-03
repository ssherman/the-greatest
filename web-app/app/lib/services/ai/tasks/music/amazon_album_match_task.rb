# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Music
        class AmazonAlbumMatchTask < BaseTask
          attr_reader :search_results

          def initialize(parent:, search_results:, provider: nil, model: nil)
            @search_results = search_results
            super(parent: parent, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def task_model = "gpt-5-mini"

          def temperature = 1.0  # GPT-5 models only support default temperature of 1.0

          def system_message
            <<~SYSTEM_MESSAGE
              You are a music expert who can determine if an Amazon product search result matches an album in our database.

              A search result is considered a match if:
              - The titles represent the same musical work (allowing for variations in subtitles or editions)
              - The artists match (allowing for variations in name format)
              - The result is the actual album, not merchandise, tribute albums, or covers

              Examples of what IS a match:
              - Different editions of the same album (remastered, deluxe, etc.)
              - Slight variations in title formatting
              - Different formats (CD, vinyl, digital)
              - Different release years for the same album
              - Artist name variations (e.g., "Depeche Mode" vs "DEPECHE MODE")

              Examples of what is NOT a match:
              - Tribute albums or cover versions
              - Merchandise or non-music items
              - Different albums by the same artist
              - Compilation albums (unless the original is also a compilation)
              - Single songs from the album
              - Soundtracks containing songs from the album

              Analyze each search result carefully to determine if it represents the same musical album.
            SYSTEM_MESSAGE
          end

          def user_prompt
            album_artists = parent.artists.map(&:name).join(", ")

            search_results_text = search_results.map do |result|
              title = result.dig("ItemInfo", "Title", "DisplayValue")
              contributors = result.dig("ItemInfo", "ByLineInfo", "Contributors") || []
              artist = contributors.find { |c| c["Role"] == "Artist" }&.dig("Name")
              binding = result.dig("ItemInfo", "Classifications", "Binding", "DisplayValue")
              manufacturer = result.dig("ItemInfo", "ByLineInfo", "Manufacturer", "DisplayValue")
              release_date = result.dig("ItemInfo", "ProductInfo", "ReleaseDate", "DisplayValue")

              <<~RESULT
                - ASIN: #{result["ASIN"]}
                  Title: #{title}
                  Artist: #{artist}
                  Format: #{binding}
                  Manufacturer: #{manufacturer}
                  Release Date: #{release_date}
              RESULT
            end.join("\n")

            <<~PROMPT
              I need to determine which of these Amazon search results match this album:

              Album from database:
              - Title: #{parent.title}
              - Artists: #{album_artists}
              #{"- Release Year: #{parent.release_year}" if parent.release_year.present?}

              Amazon search results:
              #{search_results_text}

              Please analyze each search result and return only the matching results that represent the same musical album.
              Include a brief explanation for each match. Respond with valid JSON matching the schema.
            PROMPT
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            # Extract matching results from validated data
            data = provider_response[:parsed]
            matching_results = data[:matching_results] || []

            # Return the matching results for use by the calling service
            Services::Ai::Result.new(
              success: true,
              data: {matching_results: matching_results},
              ai_chat: chat
            )
          end

          # Internal schema class
          class MatchResult < OpenAI::BaseModel
            required :asin, String, doc: "Amazon ASIN of the matching product"
            required :title, String, doc: "Product title from Amazon"
            required :artist, String, doc: "Artist name from Amazon"
            required :explanation, String, doc: "Brief explanation of why this is a match"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :matching_results, OpenAI::ArrayOf[MatchResult]
          end
        end
      end
    end
  end
end
