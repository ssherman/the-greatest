# frozen_string_literal: true

module DataImporters
  module Music
    module Song
      module Providers
        module Musicbrainz
          class Recording < DataImporters::ProviderBase
            def populate(song, query:)
              Rails.logger.info "[SONG_IMPORT] Recording provider starting for MBID: #{query.musicbrainz_recording_id || query.title}"

              api_result = if query.musicbrainz_recording_id.present?
                lookup_recording_by_mbid(query.musicbrainz_recording_id)
              else
                search_for_recording(query.title)
              end

              unless api_result[:success]
                Rails.logger.error "[SONG_IMPORT] Recording provider API failed: #{api_result[:errors]}"
                return failure_result(errors: api_result[:errors])
              end

              recordings_data = api_result[:data]["recordings"]
              if recordings_data.empty?
                Rails.logger.warn "[SONG_IMPORT] Recording provider found no recordings"
                return success_result(data_populated: [])
              end

              recording_data = recordings_data.first
              Rails.logger.info "[SONG_IMPORT] Processing recording: '#{recording_data["title"]}'"

              populate_song_data(song, recording_data)
              create_identifiers(song, recording_data)
              import_artists(song, recording_data)

              Rails.logger.info "[SONG_IMPORT] Song after populate - persisted: #{song.persisted?}, valid: #{song.valid?}, errors: #{song.errors.full_messages}"
              Rails.logger.info "[SONG_IMPORT] Song associations - identifiers: #{song.identifiers.count}, song_artists: #{song.song_artists.count}"

              Rails.logger.info "[SONG_IMPORT] Recording provider SUCCESS - populated #{data_fields_populated(recording_data).join(", ")}"
              success_result(data_populated: data_fields_populated(recording_data))
            rescue => e
              Rails.logger.error "[SONG_IMPORT] Recording provider ERROR: #{e.class} - #{e.message}"
              Rails.logger.error "[SONG_IMPORT] Backtrace: #{e.backtrace.first(3).join("\n")}"
              failure_result(errors: ["MusicBrainz recording error: #{e.message}"])
            end

            private

            def search_for_recording(title)
              search_service.search_by_title(title)
            end

            def lookup_recording_by_mbid(mbid)
              search_service.lookup_by_mbid(mbid)
            end

            def search_service
              @search_service ||= ::Music::Musicbrainz::Search::RecordingSearch.new
            end

            def populate_song_data(song, recording_data)
              song.title = recording_data["title"] if recording_data["title"].present?

              if recording_data["length"].present?
                song.duration_secs = (recording_data["length"].to_f / 1000).round
              end

              if recording_data["isrc"].present?
                song.isrc = recording_data["isrc"]
              end

              if recording_data["first-release-date"].present?
                year = recording_data["first-release-date"][0..3].to_i
                song.release_year = year if year > 1900
              end
            end

            def create_identifiers(song, recording_data)
              if recording_data["id"]
                song.identifiers.find_or_initialize_by(
                  identifier_type: :music_musicbrainz_recording_id,
                  value: recording_data["id"]
                )
              end

              if recording_data["isrc"]
                song.identifiers.find_or_initialize_by(
                  identifier_type: :music_isrc,
                  value: recording_data["isrc"]
                )
              end
            end

            def import_artists(song, recording_data)
              artist_credits = recording_data["artist-credit"]
              unless artist_credits.is_a?(Array)
                Rails.logger.warn "[SONG_IMPORT] No artist-credit array found in recording data"
                return
              end

              Rails.logger.info "[SONG_IMPORT] Importing #{artist_credits.length} artists"

              artist_credits.each_with_index do |credit, index|
                artist_data = credit["artist"]
                unless artist_data
                  Rails.logger.warn "[SONG_IMPORT] No artist data in credit #{index}"
                  next
                end

                artist_mbid = artist_data["id"]
                artist_name = artist_data["name"]

                unless artist_mbid || artist_name
                  Rails.logger.warn "[SONG_IMPORT] No MBID or name for artist at position #{index}"
                  next
                end

                Rails.logger.info "[SONG_IMPORT] Importing artist #{index}: '#{artist_name}' (#{artist_mbid})"

                artist_result = DataImporters::Music::Artist::Importer.call(
                  name: artist_name,
                  musicbrainz_id: artist_mbid
                )

                if artist_result.success? && artist_result.item
                  song.song_artists.find_or_initialize_by(
                    artist: artist_result.item,
                    position: index + 1
                  )
                  Rails.logger.info "[SONG_IMPORT] Artist #{index} imported successfully: '#{artist_result.item.name}'"
                else
                  Rails.logger.error "[SONG_IMPORT] Artist import failed for '#{artist_name}': #{artist_result.all_errors.join(", ")}"
                end
              end
            end

            def data_fields_populated(recording_data)
              fields = [:title, :musicbrainz_recording_id]

              fields << :duration if recording_data["length"]
              fields << :isrc if recording_data["isrc"]
              fields << :release_year if recording_data["first-release-date"]
              fields << :artists if recording_data["artist-credit"]

              fields
            end
          end
        end
      end
    end
  end
end
