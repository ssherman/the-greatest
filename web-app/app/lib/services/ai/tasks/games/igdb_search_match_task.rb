# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Games
        class IgdbSearchMatchTask < BaseTask
          attr_reader :search_query, :search_results, :developers

          def initialize(parent:, search_query:, search_results:, developers: [], provider: nil, model: nil)
            @search_query = search_query
            @search_results = search_results
            @developers = developers || []
            super(parent: parent, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def task_model = "gpt-5-mini"

          def temperature = 1.0

          def system_message
            <<~SYSTEM_MESSAGE
              You are a video game expert. Given a search query and a list of IGDB search results, determine which result (if any) is the best match for the intended game.

              Consider:
              - Exact or near-exact title matches are strongest signals
              - Developer names can help disambiguate similar titles
              - Prefer the original game over sequels, remakes, or DLC unless the query specifically indicates otherwise
              - If no result is a good match for the search query, return null for best_match_index
            SYSTEM_MESSAGE
          end

          def user_prompt
            lines = ["Search query: \"#{search_query}\""]
            lines << "Developers: #{developers.join(", ")}" if developers.any?
            lines << ""
            lines << "IGDB search results:"

            search_results.each_with_index do |result, index|
              entry = "#{index}. Name: \"#{result["name"]}\""

              if result["first_release_date"]
                year = Time.at(result["first_release_date"]).utc.year
                entry += ", Release year: #{year}"
              end

              if result.dig("cover", "image_id")
                entry += ", Has cover image: yes"
              end

              involved_companies = result["involved_companies"] || []
              dev_names = involved_companies
                .select { |ic| ic["developer"] }
                .map { |ic| ic.dig("company", "name") }
                .compact
              entry += ", Developers: #{dev_names.join(", ")}" if dev_names.any?

              lines << entry
            end

            lines << ""
            lines << "Which result best matches the search query? Return the 0-based index, or null if none match."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          VALID_CONFIDENCE_LEVELS = %w[high medium low none].freeze
          MATCH_CONFIDENCE_LEVELS = %w[high medium low].freeze

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            index = data[:best_match_index]
            confidence = data[:confidence]
            reasoning = data[:reasoning]

            unless VALID_CONFIDENCE_LEVELS.include?(confidence)
              return Services::Ai::Result.new(
                success: false,
                error: "Unexpected confidence value: #{confidence}",
                ai_chat: chat
              )
            end

            best_match = if index && MATCH_CONFIDENCE_LEVELS.include?(confidence) && index >= 0 && index < search_results.length
              search_results[index]
            end

            Services::Ai::Result.new(
              success: true,
              data: {
                best_match: best_match,
                best_match_index: best_match ? index : nil,
                confidence: confidence,
                reasoning: reasoning
              },
              ai_chat: chat
            )
          end

          class ResponseSchema < OpenAI::BaseModel
            required :best_match_index, Integer, nil?: true, doc: "0-based index of best matching result, or null if no good match"
            required :confidence, String, doc: "Confidence level: high, medium, low, or none"
            required :reasoning, String, doc: "Brief explanation of why this result was chosen or why none matched"
          end
        end
      end
    end
  end
end
