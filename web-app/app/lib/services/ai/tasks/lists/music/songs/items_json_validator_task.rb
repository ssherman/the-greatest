module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Songs
            class ItemsJsonValidatorTask < Services::Ai::Tasks::BaseTask
              private

              def task_provider = :openai

              def task_model = "gpt-5-mini"

              def chat_type = :analysis

              def temperature = 1.0

              def system_message
                <<~SYSTEM_MESSAGE
                  You are a music expert who validates song recording matches between original list data and MusicBrainz metadata.

                  Your task is to identify INVALID matches where the original and matched recordings are different works.

                  A match is INVALID if:
                  - Live recordings are matched with studio recordings (e.g., "Imagine" ≠ "Imagine (Live)")
                  - Cover versions are matched with originals (e.g., original by Artist A ≠ cover by Artist B)
                  - Different recordings with similar titles (e.g., "Johnny B. Goode" by Chuck Berry ≠ by Jimi Hendrix)
                  - Remix or alternate versions are matched with originals (e.g., album version ≠ remix)
                  - Significant artist name differences suggesting different works

                  A match is VALID if:
                  - Same recording with minor formatting differences
                  - Different releases of the same recording (single, album, compilation versions)
                  - Artist name variations (e.g., "The Beatles" vs "Beatles")
                  - Minor subtitle differences for the same recording

                  Return ONLY the numbers of INVALID matches. If all matches are valid, return an empty array.
                SYSTEM_MESSAGE
              end

              def user_prompt
                songs = parent.items_json["songs"]
                enriched_songs = songs.select { |song| song["mb_recording_id"].present? }

                song_matches = enriched_songs.map.with_index do |song, index|
                  number = index + 1
                  original_artists = Array(song["artists"]).join(", ")
                  original_title = song["title"]
                  matched_artists = Array(song["mb_artist_names"]).join(", ")
                  matched_title = song["mb_recording_name"]

                  "#{number}. Original: \"#{original_artists} - #{original_title}\" → Matched: \"#{matched_artists} - #{matched_title}\""
                end.join("\n")

                <<~PROMPT
                  Validate these song recording matches. Original songs from the list are matched with MusicBrainz data.
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

                songs = parent.items_json["songs"]
                enriched_counter = 0

                songs.each_with_index do |song, index|
                  if song["mb_recording_id"].present?
                    if invalid_indices.include?(enriched_counter)
                      song["ai_match_invalid"] = true
                    else
                      song.delete("ai_match_invalid")
                    end
                    enriched_counter += 1
                  end
                end

                parent.update!(items_json: {"songs" => songs})

                valid_count = enriched_counter - invalid_indices.length
                invalid_count = invalid_indices.length

                Services::Ai::Result.new(
                  success: true,
                  data: {
                    valid_count: valid_count,
                    invalid_count: invalid_count,
                    total_count: enriched_counter,
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
