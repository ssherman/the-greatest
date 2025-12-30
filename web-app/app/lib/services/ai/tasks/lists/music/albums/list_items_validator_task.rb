module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Albums
            class ListItemsValidatorTask < Services::Ai::Tasks::BaseTask
              private

              def task_provider = :openai

              def task_model = "gpt-5-mini"

              def chat_type = :analysis

              def temperature = 1.0

              def system_message
                <<~SYSTEM_MESSAGE
                  You are a music expert who validates album matches between original list data and database/MusicBrainz metadata.

                  Your task is to identify INVALID matches where the original and matched albums are different works.

                  A match is INVALID if:
                  - Live albums are matched with studio albums (e.g., "Dark Side of the Moon" ≠ "Dark Side of the Moon (Live)")
                  - Greatest Hits/Compilations matched with studio albums (e.g., "The Best of Queen" ≠ "A Night at the Opera")
                  - Tribute albums or cover versions matched with originals (e.g., "Nevermind" ≠ "Nevermind: A Tribute to Nirvana")
                  - Different albums with similar titles (e.g., "Greatest Hits" by different artists)
                  - Deluxe/Remastered editions when original was clearly intended (only if significantly different content)
                  - Significant artist name differences suggesting different works

                  A match is VALID if:
                  - Same album with minor formatting differences
                  - Different editions (remastered, deluxe, anniversary) of the same album
                  - Artist name variations (e.g., "The Beatles" vs "Beatles")
                  - Minor subtitle differences for the same work
                  - Release year within 1-2 years for different editions

                  Return ONLY the numbers of INVALID matches. If all matches are valid, return an empty array.
                SYSTEM_MESSAGE
              end

              def enriched_items
                @enriched_items ||= parent.list_items.unverified.ordered.select do |item|
                  item.listable_id.present? ||
                    item.metadata["album_id"].present? ||
                    item.metadata["mb_release_group_id"].present?
                end
              end

              def user_prompt
                return "" if enriched_items.empty?

                album_matches = enriched_items.map.with_index do |item, index|
                  number = index + 1
                  original_artists = Array(item.metadata["artists"]).join(", ")
                  original_title = item.metadata["title"]

                  if item.metadata["opensearch_match"]
                    source = "OpenSearch"
                    matched_artists = Array(item.metadata["opensearch_artist_names"]).join(", ")
                    matched_name = "#{matched_artists} - #{item.metadata["album_name"]}"
                  else
                    source = "MusicBrainz"
                    matched_artists = Array(item.metadata["mb_artist_names"]).join(", ")
                    matched_name = "#{matched_artists} - #{item.metadata["mb_release_group_name"]}"
                  end

                  "#{number}. Original: \"#{original_artists} - #{original_title}\" → Matched: \"#{matched_name}\" [#{source}]"
                end.join("\n")

                <<~PROMPT
                  Validate these album matches. Original albums from the list are matched with database/MusicBrainz data.
                  Identify any invalid matches where the original and matched albums are different works.

                  #{album_matches}

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
end
