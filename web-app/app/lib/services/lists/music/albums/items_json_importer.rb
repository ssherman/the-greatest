module Services
  module Lists
    module Music
      module Albums
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

            albums = @list.items_json["albums"]

            albums.each_with_index do |album_data, index|
              process_album(album_data, index)
            end

            Result.new(
              success: true,
              message: "Imported #{@imported_count} albums, created #{@created_directly_count} from existing albums, skipped #{@skipped_count}, #{@error_count} errors",
              imported_count: @imported_count,
              created_directly_count: @created_directly_count,
              skipped_count: @skipped_count,
              error_count: @error_count,
              data: {
                total_albums: albums.length,
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
            raise ArgumentError, "items_json must have albums array" unless @list.items_json["albums"].is_a?(Array)
            raise ArgumentError, "items_json albums array is empty" unless @list.items_json["albums"].any?
          end

          def process_album(album_data, index)
            if album_data["ai_match_invalid"] == true
              Rails.logger.info "Skipping album at index #{index}: AI flagged as invalid match"
              @skipped_count += 1
              return
            end

            unless album_data["album_id"].present? || album_data["mb_release_group_id"].present?
              Rails.logger.info "Skipping album at index #{index}: not enriched (no album_id or mb_release_group_id)"
              @skipped_count += 1
              return
            end

            rank = album_data["rank"]

            album = load_or_import_album(album_data, index)

            unless album
              Rails.logger.error "Failed to load/import album at index #{index}: #{album_data["title"]}"
              @error_count += 1
              @errors << "Failed to load/import: #{album_data["title"]}"
              return
            end

            create_list_item_if_needed(album, rank, index)
          rescue => e
            Rails.logger.error "Error processing album at index #{index}: #{e.message}"
            @error_count += 1
            @errors << "Error at index #{index}: #{e.message}"
          end

          def load_or_import_album(album_data, index)
            if album_data["album_id"].present?
              Rails.logger.info "Loading existing album at index #{index}: #{album_data["album_name"]} (ID: #{album_data["album_id"]})"
              album = ::Music::Album.find_by(id: album_data["album_id"])

              if album
                @created_directly_count += 1 if create_will_succeed?(album)
                return album
              else
                Rails.logger.warn "Album ID #{album_data["album_id"]} not found, will try import if MusicBrainz ID available"
              end
            end

            if album_data["mb_release_group_id"].present?
              Rails.logger.info "Importing album at index #{index}: #{album_data["title"]} (MusicBrainz ID: #{album_data["mb_release_group_id"]})"
              album = import_album(album_data["mb_release_group_id"])
              @imported_count += 1 if album && create_will_succeed?(album)
              return album
            end

            nil
          end

          def import_album(mb_release_group_id)
            result = DataImporters::Music::Album::Importer.call(
              release_group_musicbrainz_id: mb_release_group_id
            )

            if result.success?
              result.item
            else
              Rails.logger.error "Album import failed for #{mb_release_group_id}: #{result.all_errors.join(", ")}"
              nil
            end
          end

          def create_will_succeed?(album)
            !@list.list_items.exists?(listable: album)
          end

          def create_list_item_if_needed(album, rank, index)
            existing_item = @list.list_items.find_by(listable: album)
            if existing_item
              Rails.logger.info "List item already exists for album: #{album.title} (position: #{existing_item.position})"
              @skipped_count += 1
              return
            end

            @list.list_items.create!(
              listable: album,
              position: rank,
              verified: true
            )

            Rails.logger.info "Created list_item for #{album.title} at position #{rank}"
          end
        end
      end
    end
  end
end
