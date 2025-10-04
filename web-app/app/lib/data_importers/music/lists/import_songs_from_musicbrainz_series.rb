# frozen_string_literal: true

module DataImporters
  module Music
    module Lists
      class ImportSongsFromMusicbrainzSeries
        def self.call(list:)
          new(list: list).call
        end

        def initialize(list:)
          @list = list
        end

        def call
          validate_list!

          series_data = fetch_series_data
          return failure_result("Failed to fetch series data") unless series_data

          import_results = import_songs_from_series(series_data)
          create_list_items(import_results)

          success_result(import_results)
        rescue => e
          Rails.logger.error "ImportSongsFromMusicbrainzSeries failed: #{e.message}"
          failure_result(e.message)
        end

        private

        attr_reader :list

        def validate_list!
          raise ArgumentError, "List must have musicbrainz_series_id" if list.musicbrainz_series_id.blank?
          raise ArgumentError, "List must be a Music::Songs::List" unless list.is_a?(::Music::Songs::List)
        end

        def fetch_series_data
          series_search = ::Music::Musicbrainz::Search::SeriesSearch.new
          result = series_search.browse_series_with_recordings(list.musicbrainz_series_id)

          if result[:success] && result[:data]
            result[:data]
          else
            Rails.logger.error "No series data found for MBID: #{list.musicbrainz_series_id}. Error: #{result[:errors] if result}"
            nil
          end
        end

        def import_songs_from_series(series_data)
          recordings = extract_recordings(series_data)
          import_results = []

          Rails.logger.info "[SONG_SERIES_IMPORT] Starting import of #{recordings.length} recordings from series #{list.musicbrainz_series_id}"

          recordings.each do |recording_data|
            recording_id = recording_data.dig("recording", "id")
            recording_title = recording_data.dig("recording", "title")
            position = recording_data.dig("attribute-values", "number")&.to_i

            unless recording_id
              Rails.logger.warn "[SONG_SERIES_IMPORT] Skipping recording with no ID at position #{position}"
              next
            end

            Rails.logger.info "[SONG_SERIES_IMPORT] Position #{position}: Importing '#{recording_title}' (#{recording_id})"

            begin
              song = import_song(recording_id)

              import_results << if song
                Rails.logger.info "[SONG_SERIES_IMPORT] Position #{position}: SUCCESS - '#{song.title}' (#{recording_id})"
                {
                  song: song,
                  position: position,
                  recording_id: recording_id,
                  success: true
                }
              else
                Rails.logger.error "[SONG_SERIES_IMPORT] Position #{position}: FAILED - '#{recording_title}' (#{recording_id}) - Import returned nil"
                {
                  position: position,
                  recording_id: recording_id,
                  success: false,
                  error: "Song import failed"
                }
              end
            rescue => e
              Rails.logger.error "[SONG_SERIES_IMPORT] Position #{position}: ERROR - '#{recording_title}' (#{recording_id}) - #{e.class}: #{e.message}"
              Rails.logger.error "[SONG_SERIES_IMPORT] Backtrace: #{e.backtrace.first(3).join("\n")}"
              import_results << {
                position: position,
                recording_id: recording_id,
                success: false,
                error: e.message
              }
            end
          end

          Rails.logger.info "[SONG_SERIES_IMPORT] Import complete: #{import_results.count { |r| r[:success] }}/#{import_results.length} succeeded"
          import_results
        end

        def extract_recordings(series_data)
          relations = series_data["relations"] || []
          relations.select { |rel| rel["target-type"] == "recording" }
        end

        def import_song(recording_id)
          song = ::Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first
          if song
            Rails.logger.info "[SONG_SERIES_IMPORT] Found existing song: '#{song.title}' (#{recording_id})"
            return song
          end

          Rails.logger.info "[SONG_SERIES_IMPORT] Calling Song::Importer for #{recording_id}"
          result = DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: recording_id)

          if result.success?
            Rails.logger.info "[SONG_SERIES_IMPORT] Song::Importer SUCCESS for #{recording_id} - item: #{result.item.inspect}"
            if result.item && result.item.id.nil?
              Rails.logger.error "[SONG_SERIES_IMPORT] Song has no ID (not saved)! Validation errors: #{result.item.errors.full_messages.join(", ")}"
              Rails.logger.error "[SONG_SERIES_IMPORT] Song attributes: #{result.item.attributes.inspect}"
              return nil
            end
            result.item
          else
            Rails.logger.error "[SONG_SERIES_IMPORT] Song::Importer FAILED for #{recording_id}"
            Rails.logger.error "[SONG_SERIES_IMPORT] - All errors: #{result.all_errors.join(", ")}"
            Rails.logger.error "[SONG_SERIES_IMPORT] - Provider results: #{result.provider_results.map { |pr| "#{pr.provider_name}: success=#{pr.success?}, errors=#{pr.errors}" }.join(" | ")}"
            nil
          end
        end

        def create_list_items(import_results)
          successful_imports = import_results.select { |r| r[:success] && r[:song] }

          successful_imports.each do |import_result|
            song = import_result[:song]
            position = import_result[:position]

            existing_item = list.list_items.find_by(listable: song)
            next if existing_item

            list.list_items.create!(
              listable: song,
              position: position || 0
            )

            Rails.logger.info "Created list item for #{song.title} at position #{position}"
          end
        end

        def success_result(import_results)
          successful_count = import_results.count { |r| r[:success] }
          {
            success: true,
            message: "Imported #{successful_count} of #{import_results.length} songs",
            imported_count: successful_count,
            total_count: import_results.length,
            results: import_results
          }
        end

        def failure_result(error_message)
          {
            success: false,
            message: error_message,
            imported_count: 0,
            total_count: 0,
            results: []
          }
        end
      end
    end
  end
end
