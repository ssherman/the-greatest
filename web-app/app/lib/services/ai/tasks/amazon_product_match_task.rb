# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      # Base class for Amazon product matching AI tasks
      # Subclasses implement domain-specific matching criteria and response schemas
      class AmazonProductMatchTask < BaseTask
        attr_reader :search_results

        def initialize(parent:, search_results:, provider: nil, model: nil)
          @search_results = search_results
          super(parent: parent, provider: provider, model: model)
        end

        private

        def task_provider = :openai

        def task_model = "gpt-5-mini"

        def temperature = 1.0 # GPT-5 models only support default temperature of 1.0

        # Subclasses must implement these methods
        def domain_name
          raise NotImplementedError, "Subclasses must implement #domain_name"
        end

        def item_description
          raise NotImplementedError, "Subclasses must implement #item_description"
        end

        def match_criteria
          raise NotImplementedError, "Subclasses must implement #match_criteria"
        end

        def non_match_criteria
          raise NotImplementedError, "Subclasses must implement #non_match_criteria"
        end

        # Build system message from domain-specific criteria
        def system_message
          <<~SYSTEM_MESSAGE
            You are a #{domain_name} expert who can determine if an Amazon product search result matches an item in our database.

            A search result is considered a match if:
            #{match_criteria}

            Examples of what is NOT a match:
            #{non_match_criteria}

            Analyze each search result carefully to determine if it represents a match.
          SYSTEM_MESSAGE
        end

        # Build user prompt from domain-specific item description
        def user_prompt
          <<~PROMPT
            I need to determine which of these Amazon search results match this #{domain_name}:

            #{domain_name.capitalize} from database:
            #{item_description}

            Amazon search results:
            #{format_search_results}

            Please analyze each search result and return only the matching results.
            Include a brief explanation for each match. Respond with valid JSON matching the schema.
          PROMPT
        end

        def response_format = {type: "json_object"}

        def response_schema
          self.class::ResponseSchema
        end

        def process_and_persist(provider_response)
          data = provider_response[:parsed]
          matching_results = data[:matching_results] || []

          Services::Ai::Result.new(
            success: true,
            data: {matching_results: matching_results},
            ai_chat: chat
          )
        end

        # Format Amazon search results for the prompt
        def format_search_results
          search_results.map do |result|
            format_search_result(result)
          end.join("\n")
        end

        # Default search result formatting - can be overridden
        def format_search_result(result)
          title = result.dig("ItemInfo", "Title", "DisplayValue")
          contributors = result.dig("ItemInfo", "ByLineInfo", "Contributors") || []
          creator = contributors.first&.dig("Name")
          binding = result.dig("ItemInfo", "Classifications", "Binding", "DisplayValue")
          manufacturer = result.dig("ItemInfo", "ByLineInfo", "Manufacturer", "DisplayValue")
          release_date = result.dig("ItemInfo", "ProductInfo", "ReleaseDate", "DisplayValue")

          <<~RESULT
            - ASIN: #{result["ASIN"]}
              Title: #{title}
              Creator: #{creator}
              Format: #{binding}
              Manufacturer: #{manufacturer}
              Release Date: #{release_date}
          RESULT
        end
      end
    end
  end
end
