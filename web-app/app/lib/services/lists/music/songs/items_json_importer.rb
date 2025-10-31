module Services
  module Lists
    module Music
      module Songs
        class ItemsJsonImporter
          Result = Struct.new(:success, :data, :message, :imported_count, :created_directly_count, :skipped_count, :error_count, keyword_init: true)

          def self.call(list:)
            new(list: list).call
          end

          def initialize(list:)
            @list = list
            @imported_count = 0
            @created_directly_count = 0
            @skipped_count = 0
            @error_count = 0
            @errors = []
          end

          def call
            validate_list!

            songs = @list.items_json["songs"]

            songs.each_with_index do |song_data, index|
              process_song(song_data, index)
            end

            Result.new(
              success: true,
              message: "Imported #{@imported_count} songs, created #{@created_directly_count} from existing songs, skipped #{@skipped_count}, #{@error_count} errors",
              imported_count: @imported_count,
              created_directly_count: @created_directly_count,
              skipped_count: @skipped_count,
              error_count: @error_count,
              data: {
                total_songs: songs.length,
                imported: @imported_count,
                created_directly: @created_directly_count,
                skipped: @skipped_count,
                errors: @error_count,
                error_messages: @errors
              }
            )
          rescue ArgumentError
            raise
          rescue => e
            Rails.logger.error "ItemsJsonImporter failed: #{e.message}"
            Result.new(
              success: false,
              message: "Import failed: #{e.message}",
              imported_count: @imported_count,
              created_directly_count: @created_directly_count,
              skipped_count: @skipped_count,
              error_count: @error_count,
              data: {errors: [@errors + [e.message]].flatten}
            )
          end

          private

          def validate_list!
            raise ArgumentError, "List is required" unless @list
            raise ArgumentError, "List must have items_json" unless @list.items_json.present?
            raise ArgumentError, "items_json must have songs array" unless @list.items_json["songs"].is_a?(Array)
            raise ArgumentError, "items_json songs array is empty" unless @list.items_json["songs"].any?
          end

          def process_song(song_data, index)
            if song_data["ai_match_invalid"] == true
              Rails.logger.info "Skipping song at index #{index}: AI flagged as invalid match"
              @skipped_count += 1
              return
            end

            unless song_data["song_id"].present? || song_data["mb_recording_id"].present?
              Rails.logger.info "Skipping song at index #{index}: not enriched (no song_id or mb_recording_id)"
              @skipped_count += 1
              return
            end

            rank = song_data["rank"]

            song = load_or_import_song(song_data, index)

            unless song
              Rails.logger.error "Failed to load/import song at index #{index}: #{song_data["title"]}"
              @error_count += 1
              @errors << "Failed to load/import: #{song_data["title"]}"
              return
            end

            create_list_item_if_needed(song, rank, index)
          rescue => e
            Rails.logger.error "Error processing song at index #{index}: #{e.message}"
            @error_count += 1
            @errors << "Error at index #{index}: #{e.message}"
          end

          def load_or_import_song(song_data, index)
            if song_data["song_id"].present?
              Rails.logger.info "Loading existing song at index #{index}: #{song_data["song_name"]} (ID: #{song_data["song_id"]})"
              song = ::Music::Song.find_by(id: song_data["song_id"])

              if song
                @created_directly_count += 1 if create_will_succeed?(song)
                return song
              else
                Rails.logger.warn "Song ID #{song_data["song_id"]} not found, will try import if MusicBrainz ID available"
              end
            end

            if song_data["mb_recording_id"].present?
              Rails.logger.info "Importing song at index #{index}: #{song_data["title"]} (MusicBrainz ID: #{song_data["mb_recording_id"]})"
              song = import_song(song_data["mb_recording_id"])
              @imported_count += 1 if song && create_will_succeed?(song)
              return song
            end

            nil
          end

          def import_song(mb_recording_id)
            result = DataImporters::Music::Song::Importer.call(
              musicbrainz_recording_id: mb_recording_id
            )

            if result.success?
              result.item
            else
              Rails.logger.error "Song import failed for #{mb_recording_id}: #{result.all_errors.join(", ")}"
              nil
            end
          end

          def create_will_succeed?(song)
            !@list.list_items.exists?(listable: song)
          end

          def create_list_item_if_needed(song, rank, index)
            existing_item = @list.list_items.find_by(listable: song)
            if existing_item
              Rails.logger.info "List item already exists for song: #{song.title} (position: #{existing_item.position})"
              @skipped_count += 1
              return
            end

            @list.list_items.create!(
              listable: song,
              position: rank,
              verified: true
            )

            Rails.logger.info "Created list_item for #{song.title} at position #{rank}"
          end
        end
      end
    end
  end
end
