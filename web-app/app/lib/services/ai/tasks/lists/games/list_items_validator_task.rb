# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        module Games
          class ListItemsValidatorTask < Services::Ai::Tasks::BaseTask
            # Override BaseTask initializer to accept optional items parameter.
            # When items: is provided (for batch processing), validates those items
            # instead of fetching from parent. AI chat is still associated with parent.
            def initialize(parent:, items: nil, provider: nil, model: nil)
              @provided_items = items
              super(parent: parent, provider: provider, model: model)
            end

            private

            def task_provider = :openai

            def task_model = "gpt-5-mini"

            def chat_type = :analysis

            def temperature = 1.0

            def system_message
              <<~SYSTEM_MESSAGE
                You are a video game expert who validates game matches between original list data and database/IGDB metadata.

                Your task is to identify INVALID matches where the original and matched games are different works.

                A match is INVALID if:
                - Different games with similar titles (e.g., "Resident Evil" 1996 ≠ "Resident Evil" 2023 remake)
                - DLC or expansion matched with the base game (e.g., "The Witcher 3: Blood and Wine" ≠ "The Witcher 3: Wild Hunt")
                - Different entries in the same franchise (e.g., "Final Fantasy VII" ≠ "Final Fantasy VII Remake")
                - Remasters/remakes matched with originals when the original was clearly intended
                - Significantly different developer attribution suggesting a different game
                - Bundle editions matched with individual games

                A match is VALID if:
                - Same game with minor formatting differences
                - Different editions (GOTY, Definitive, Complete) of the same game
                - Developer name variations (e.g., "CD Projekt Red" vs "CD Projekt RED")
                - Minor subtitle differences for the same work
                - Release year within 1-2 years for regional releases

                Return ONLY the numbers of INVALID matches. If all matches are valid, return an empty array.
              SYSTEM_MESSAGE
            end

            def enriched_items
              @enriched_items ||= @provided_items || parent.list_items.unverified.ordered.select do |item|
                item.listable_id.present? ||
                  item.metadata["game_id"].present? ||
                  item.metadata["igdb_id"].present?
              end
            end

            def user_prompt
              return "" if enriched_items.empty?

              game_matches = enriched_items.map.with_index do |item, index|
                number = index + 1
                original_developers = Array(item.metadata["developers"]).join(", ")
                original_title = item.metadata["title"]

                if item.metadata["opensearch_match"]
                  source = "OpenSearch"
                  matched_name = item.metadata["game_name"]
                else
                  source = "IGDB"
                  matched_developers = Array(item.metadata["igdb_developer_names"]).join(", ")
                  matched_name = "#{item.metadata["igdb_name"]}#{" by #{matched_developers}" if matched_developers.present?}"
                end

                "#{number}. Original: \"#{original_title}\" by #{original_developers} → Matched: \"#{matched_name}\" [#{source}]"
              end.join("\n")

              <<~PROMPT
                Validate these game matches. Original games from the list are matched with database/IGDB data.
                Identify any invalid matches where the original and matched games are different works.

                #{game_matches}

                Which matches are invalid? Return array of numbers for invalid matches.
              PROMPT
            end

            def response_format = {type: "json_object"}

            def response_schema
              ResponseSchema
            end

            def process_and_persist(provider_response)
              data = provider_response[:parsed]
              invalid_indices = data[:invalid].map { |num| num - 1 }

              valid_count = 0
              invalid_count = 0
              verified_count = 0

              enriched_items.each_with_index do |item, index|
                if invalid_indices.include?(index)
                  invalid_count += 1
                  item.metadata["ai_match_invalid"] = true
                  item.listable_id = nil if item.listable_id.present?
                else
                  valid_count += 1
                  item.metadata.delete("ai_match_invalid")
                  item.verified = true
                  verified_count += 1
                end
                item.save!
              end

              Services::Ai::Result.new(
                success: true,
                data: {
                  valid_count: valid_count,
                  invalid_count: invalid_count,
                  verified_count: verified_count,
                  total_count: enriched_items.count,
                  invalid_indices: invalid_indices,
                  reasoning: data[:reasoning]
                },
                ai_chat: chat
              )
            end

            class ResponseSchema < OpenAI::BaseModel
              required :invalid, OpenAI::ArrayOf[Integer], doc: "Array of item numbers that are invalid matches"
              required :reasoning, String, nil?: true, doc: "Brief explanation of validation approach"
            end
          end
        end
      end
    end
  end
end
