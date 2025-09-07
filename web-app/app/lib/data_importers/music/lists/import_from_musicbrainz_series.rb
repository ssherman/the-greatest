# frozen_string_literal: true

module DataImporters
  module Music
    module Lists
      class ImportFromMusicbrainzSeries
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

          import_results = import_albums_from_series(series_data)
          create_list_items(import_results)

          success_result(import_results)
        rescue => e
          Rails.logger.error "ImportFromMusicbrainzSeries failed: #{e.message}"
          failure_result(e.message)
        end

        private

        attr_reader :list

        def validate_list!
          raise ArgumentError, "List must have musicbrainz_series_id" if list.musicbrainz_series_id.blank?
          raise ArgumentError, "List must be a Music::Albums::List" unless list.is_a?(::Music::Albums::List)
        end

        def fetch_series_data
          series_search = ::Music::Musicbrainz::Search::SeriesSearch.new
          result = series_search.browse_series_with_release_groups(list.musicbrainz_series_id)

          if result[:success] && result[:data]
            result[:data]
          else
            Rails.logger.error "No series data found for MBID: #{list.musicbrainz_series_id}. Error: #{result[:errors] if result}"
            nil
          end
        end

        def import_albums_from_series(series_data)
          release_groups = extract_release_groups(series_data)
          import_results = []

          release_groups.each do |rg_data|
            release_group_id = rg_data.dig("release_group", "id")
            position = rg_data.dig("attribute-values", "number")&.to_i

            next unless release_group_id

            Rails.logger.info "Importing release group: #{release_group_id} at position #{position}"

            begin
              # Import the album using existing importer
              album = import_album(release_group_id)

              import_results << if album
                {
                  album: album,
                  position: position,
                  release_group_id: release_group_id,
                  success: true
                }
              else
                {
                  position: position,
                  release_group_id: release_group_id,
                  success: false,
                  error: "Album import failed"
                }
              end
            rescue => e
              Rails.logger.error "Failed to import release group #{release_group_id}: #{e.message}"
              import_results << {
                position: position,
                release_group_id: release_group_id,
                success: false,
                error: e.message
              }
            end
          end

          import_results
        end

        def extract_release_groups(series_data)
          relations = series_data["relations"] || []
          relations.select { |rel| rel["target-type"] == "release_group" }
        end

        def import_album(release_group_id)
          # Find existing album first
          album = ::Music::Album.with_musicbrainz_release_group_id(release_group_id).first
          return album if album

          # Import new album using existing album importer
          result = DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id: release_group_id)

          if result.success?
            result.item
          else
            Rails.logger.error "Album importer failed for #{release_group_id}: #{result.all_errors.join(", ")}"
            nil
          end
        end

        def create_list_items(import_results)
          successful_imports = import_results.select { |r| r[:success] && r[:album] }

          successful_imports.each do |import_result|
            album = import_result[:album]
            position = import_result[:position]

            # Avoid duplicates
            existing_item = list.list_items.find_by(listable: album)
            next if existing_item

            list.list_items.create!(
              listable: album,
              position: position || 0
            )

            Rails.logger.info "Created list item for #{album.title} at position #{position}"
          end
        end

        def success_result(import_results)
          successful_count = import_results.count { |r| r[:success] }
          {
            success: true,
            message: "Imported #{successful_count} of #{import_results.length} albums",
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
