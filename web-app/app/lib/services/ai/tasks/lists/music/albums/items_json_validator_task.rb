module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Albums
            class ItemsJsonValidatorTask < Services::Ai::Tasks::BaseTask
              private

              def task_provider = :openai

              def task_model = "gpt-5-mini"

              def chat_type = :analysis

              def temperature = 1.0

              def system_message
                <<~SYSTEM_MESSAGE
                  You are a music expert who validates album matches between original list data and MusicBrainz metadata.

                  Your task is to identify INVALID matches where the original and matched albums are different works.

                  A match is INVALID if:
                  - Live albums are matched with non-live albums (e.g., "Dark Side of the Moon" ≠ "Dark Side of the Moon (Live)")
                  - Tribute albums or cover versions are matched with originals (e.g., "Nevermind" ≠ "Nevermind: A Tribute to Nirvana")
                  - Different albums with similar titles (e.g., "Greatest Hits" by different artists)
                  - Compilations matched with studio albums (e.g., "The Best of Queen" ≠ "A Night at the Opera")
                  - Significant artist name differences suggesting different works

                  A match is VALID if:
                  - Same album with minor formatting differences
                  - Different editions (remastered, deluxe, etc.)
                  - Artist name variations (e.g., "The Beatles" vs "Beatles")
                  - Minor subtitle differences for the same work

                  Return ONLY the numbers of INVALID matches. If all matches are valid, return an empty array.
                SYSTEM_MESSAGE
              end

              def user_prompt
                albums = parent.items_json["albums"]
                enriched_albums = albums.select { |album| album["mb_release_group_id"].present? }

                album_matches = enriched_albums.map.with_index do |album, index|
                  number = index + 1
                  original_artists = Array(album["artists"]).join(", ")
                  original_title = album["title"]
                  matched_artists = Array(album["mb_artist_names"]).join(", ")
                  matched_title = album["mb_release_group_name"]

                  "#{number}. Original: \"#{original_artists} - #{original_title}\" → Matched: \"#{matched_artists} - #{matched_title}\""
                end.join("\n")

                <<~PROMPT
                  Validate these album matches. Original albums from the list are matched with MusicBrainz data.
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

                albums = parent.items_json["albums"]
                enriched_counter = 0

                albums.each_with_index do |album, index|
                  if album["mb_release_group_id"].present?
                    if invalid_indices.include?(enriched_counter)
                      album["ai_match_invalid"] = true
                    else
                      album.delete("ai_match_invalid")
                    end
                    enriched_counter += 1
                  end
                end

                parent.update!(items_json: {"albums" => albums})

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
