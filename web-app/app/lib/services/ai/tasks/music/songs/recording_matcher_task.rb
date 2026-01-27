module Services
  module Ai
    module Tasks
      module Music
        module Songs
          class RecordingMatcherTask < BaseTask
            # Override BaseTask initializer to accept candidates parameter.
            # Candidates are the MusicBrainz recording search results to filter.
            def initialize(parent:, candidates:, provider: nil, model: nil)
              @candidates = candidates || []
              super(parent: parent, provider: provider, model: model)
            end

            private

            attr_reader :candidates

            def task_provider = :openai

            def task_model = "gpt-5-mini"

            def chat_type = :analysis

            def system_message
              <<~SYSTEM_MESSAGE
                You are a music expert identifying which MusicBrainz recordings are exact
                matches for a given song.

                Given a song's metadata and MusicBrainz candidate recordings, identify which
                recordings represent the SAME VERSION of the song.

                IMPORTANT: Match the song AS IT IS, not necessarily the "original studio version."
                - If the song title indicates it's a remix (e.g., "Song (Club Mix)"), match OTHER
                  recordings of that SAME remix, not the original.
                - If the song title indicates it's a live version, match OTHER live recordings.
                - If the song is the standard studio version, match other studio recordings.

                INCLUDE as exact matches:
                - Recordings that are the same version/mix as the input song
                - Different pressings or releases of the same recording
                - Mono/stereo variants of the same recording

                EXCLUDE (not the same version):
                - Different mixes/remixes than what the song title indicates
                - Live versions (if the song is a studio version)
                - Studio versions (if the song is a live version)
                - Remasters (same recording, different release - exclude to avoid confusion)
                - Cover versions by other artists
                - Karaoke/instrumental versions
                - Demo versions (unless the song is specifically a demo)

                Return the MBIDs of recordings that match the same version as the input song.
              SYSTEM_MESSAGE
            end

            def user_prompt
              return "" if candidates.empty?

              song_info = build_song_info
              candidates_list = build_candidates_list

              <<~PROMPT
                Match MusicBrainz recordings to this song:

                SONG:
                #{song_info}

                CANDIDATE RECORDINGS:
                #{candidates_list}

                Which recordings are exact matches for the same version of this song?
                Return array of MBIDs for recordings that match.
              PROMPT
            end

            def response_format = {type: "json_object"}

            def response_schema
              ResponseSchema
            end

            def process_and_persist(provider_response)
              data = provider_response[:parsed]

              Services::Ai::Result.new(
                success: true,
                data: {
                  exact_matches: data[:exact_matches] || [],
                  reasoning: data[:reasoning],
                  excluded: data[:excluded] || []
                },
                ai_chat: chat
              )
            end

            def build_song_info
              artist_names = parent.artists.map(&:name).join(", ")
              parts = []
              parts << "Title: \"#{parent.title}\""
              parts << "Artist(s): #{artist_names}" if artist_names.present?
              # NOTE: Intentionally NOT including release_year - we want the AI to match
              # recordings from ANY year so we can find the earliest first-release-date
              parts.join("\n")
            end

            def build_candidates_list
              candidates.map.with_index(1) do |candidate, index|
                artist_credit = candidate["artist-credit"]&.map { |ac| ac["name"] }&.join(", ") || "Unknown"
                first_release = candidate["first-release-date"] || "Unknown"
                disambiguation = candidate["disambiguation"]

                line = "#{index}. MBID: #{candidate["id"]}"
                line += "\n   Title: \"#{candidate["title"]}\""
                line += "\n   Artist: #{artist_credit}"
                line += "\n   First release: #{first_release}"
                line += "\n   Disambiguation: #{disambiguation}" if disambiguation.present?
                line
              end.join("\n\n")
            end

            class ExcludedRecording < OpenAI::BaseModel
              required :mbid, String, doc: "MusicBrainz ID of excluded recording"
              required :reason, String, doc: "Reason for exclusion"
            end

            class ResponseSchema < OpenAI::BaseModel
              required :exact_matches, OpenAI::ArrayOf[String], doc: "Array of MBIDs that are exact matches for the original song"
              required :reasoning, String, nil?: true, doc: "Explanation of filtering decisions"
              required :excluded, OpenAI::ArrayOf[ExcludedRecording], nil?: true, doc: "Recordings excluded and why"
            end
          end
        end
      end
    end
  end
end
