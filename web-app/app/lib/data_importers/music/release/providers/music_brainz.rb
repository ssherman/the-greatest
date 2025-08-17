# frozen_string_literal: true

module DataImporters
  module Music
    module Release
      module Providers
        class MusicBrainz < ProviderBase
          def populate(item, query:)
            album = query.album
            release_group_mbid = get_release_group_mbid(album)
            return failure_result(errors: ["No release group MBID found for album"]) unless release_group_mbid

            # Search for all releases in this release group
            release_search = ::Music::Musicbrainz::Search::ReleaseSearch.new
            search_results = release_search.search_by_release_group_mbid(release_group_mbid)

            return failure_result(errors: ["No releases found in MusicBrainz"]) unless search_results&.dig(:data, "releases")&.any?

            # Process all releases and create Music::Release records for each
            releases_created = 0
            errors = []

            search_results[:data]["releases"].each do |release_data|
              # Check if this release already exists
              existing_release = find_existing_release(release_data["id"], album)
              next if existing_release

              # Create new release
              new_release = create_release_from_data(release_data, album)
              if new_release.save
                releases_created += 1
                create_identifiers(new_release, release_data)
              else
                errors << "Failed to save release: #{new_release.errors.full_messages.join(", ")}"
              end
            rescue => e
              errors << "Error processing release #{release_data["id"]}: #{e.message}"
            end

            if releases_created > 0
              success_result(data_populated: [:releases_created])
            else
              failure_result(errors: errors.any? ? errors : ["No new releases created"])
            end
          end

          private

          def get_release_group_mbid(album)
            identifier = album.identifiers.find_by(identifier_type: :music_musicbrainz_release_group_id)
            identifier&.value
          end

          def find_existing_release(release_mbid, album)
            album.releases
              .joins(:identifiers)
              .where(identifiers: {
                identifier_type: :music_musicbrainz_release_id,
                value: release_mbid
              })
              .first
          end

          def create_release_from_data(release_data, album)
            ::Music::Release.new(
              album: album,
              release_name: release_data["title"],
              release_date: parse_release_date(release_data["date"]),
              country: release_data["country"],
              status: parse_status(release_data["status"]),
              format: parse_format(release_data),
              labels: parse_labels(release_data["label-info"]),
              metadata: build_metadata(release_data)
            )
          end

          def create_identifiers(release, release_data)
            # Create MusicBrainz release identifier
            release.identifiers.create!(
              identifier_type: :music_musicbrainz_release_id,
              value: release_data["id"]
            )

            # Create ASIN identifier if present
            if release_data["asin"].present?
              release.identifiers.create!(
                identifier_type: :music_asin,
                value: release_data["asin"]
              )
            end
          end

          def parse_release_date(date_string)
            return nil if date_string.blank?

            Date.parse(date_string)
          rescue Date::Error
            nil
          end

          def parse_status(status_string)
            return :official if status_string.blank?

            case status_string.downcase
            when "official" then :official
            when "promotion" then :promotion
            when "bootleg" then :bootleg
            when "pseudo-release" then :pseudo_release
            when "withdrawn" then :withdrawn
            when "expunged" then :expunged
            when "cancelled" then :cancelled
            else :official
            end
          end

          def parse_format(release_data)
            media = release_data["media"]
            return :other if media.blank? || !media.is_a?(Array) || media.empty?

            # Take the first media item's format
            format_string = media.first["format"]
            return :other if format_string.blank?

            case format_string.downcase
            # CD formats (be specific to avoid matching SACD, etc.)
            when /^cd$/, /compact disc/, /copy control cd/, /data cd/, /dts cd/,
                 /enhanced cd/, /hdcd/, /mixed mode cd/, /cd-r/, /8cm cd/,
                 /blu-spec cd/, /minimax cd/, /shm-cd/, /hqcd/, /cd\+g/
              :cd
            # Vinyl formats
            when /vinyl/, /flexi-disc/, /gramophone record/, /elcaset/
              :vinyl
            # Digital formats
            when /digital/, /download card/, /usb flash drive/
              :digital
            # Cassette formats
            when /cassette/, /microcassette/
              :cassette
            else
              :other
            end
          end

          def parse_labels(label_info)
            return [] if label_info.blank? || !label_info.is_a?(Array)

            label_info.map { |info| info.dig("label", "name") }.compact.uniq
          end

          def build_metadata(release_data)
            {
              asin: release_data["asin"],
              barcode: release_data["barcode"],
              packaging: release_data["packaging"],
              media: release_data["media"],
              text_representation: release_data["text-representation"],
              release_events: release_data["release-events"]
            }.compact
          end
        end
      end
    end
  end
end
