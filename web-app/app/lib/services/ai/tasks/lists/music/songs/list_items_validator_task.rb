module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Songs
            class ListItemsValidatorTask < Services::Ai::Tasks::BaseTask
              private

              def task_provider = :openai

              def task_model = "gpt-5-mini"

              def chat_type = :analysis

              def temperature = 1.0

              def system_message
                <<~SYSTEM_MESSAGE
                  You are a music expert who validates song recording matches between original list data and database/MusicBrainz metadata.

                  Your task is to identify INVALID matches where the original and matched recordings are different works.

                  A match is INVALID if:
                  - Live recordings are matched with studio recordings (e.g., "Imagine" ≠ "Imagine (Live)")
                  - Cover versions are matched with originals (e.g., original by Artist A ≠ cover by Artist B)
                  - Different recordings with similar titles (e.g., "Johnny B. Goode" by Chuck Berry ≠ by Jimi Hendrix)
                  - Remix or alternate versions are matched with originals (e.g., album version ≠ remix)
                  - Significant artist name differences suggesting different works
                  - Completely different songs matched due to fuzzy matching (e.g., "Time" by Pink Floyd ≠ "The Time" by Morris Day)

                  A match is VALID if:
                  - Same recording with minor formatting differences
                  - Different releases of the same recording (single, album, compilation versions)
                  - Artist name variations (e.g., "The Beatles" vs "Beatles")
                  - Minor subtitle differences for the same recording

                  Return ONLY the numbers of INVALID matches. If all matches are valid, return an empty array.
                SYSTEM_MESSAGE
              end

              def enriched_items
                @enriched_items ||= parent.list_items.unverified.ordered.select do |item|
                  item.listable_id.present? ||
                    item.metadata["song_id"].present? ||
                    item.metadata["mb_recording_id"].present?
                end
              end

              def user_prompt
                return "" if enriched_items.empty?

                song_matches = enriched_items.map.with_index do |item, index|
                  number = index + 1
                  original_artists = Array(item.metadata["artists"]).join(", ")
                  original_title = item.metadata["title"]

                  if item.metadata["opensearch_match"]
                    source = "OpenSearch"
                    matched_name = item.metadata["song_name"]
                  else
                    source = "MusicBrainz"
                    matched_artists = Array(item.metadata["mb_artist_names"]).join(", ")
                    matched_name = "#{matched_artists} - #{item.metadata["mb_recording_name"]}"
                  end

                  "#{number}. Original: \"#{original_artists} - #{original_title}\" → Matched: \"#{matched_name}\" [#{source}]"
                end.join("\n")

                <<~PROMPT
                  Validate these song recording matches. Original songs from the list are matched with database/MusicBrainz data.
                  Identify any invalid matches where the original and matched recordings are different works.

                  #{song_matches}

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
                    # Clear listable_id for any invalid match to prevent incorrect rankings
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
