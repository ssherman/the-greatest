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

            # Search for all releases in this release group with recordings and media data
            release_search = ::Music::Musicbrainz::Search::ReleaseSearch.new
            search_results = release_search.search_by_release_group_mbid_with_recordings(release_group_mbid)

            return failure_result(errors: ["No releases found in MusicBrainz"]) unless search_results&.dig(:data, "releases")&.any?

            # Process all releases and create Music::Release, Song, and Track records
            releases_created = 0
            songs_created = 0
            tracks_created = 0
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

                # Create songs and tracks for this release
                song_track_result = create_songs_and_tracks(new_release, release_data)
                songs_created += song_track_result[:songs_created]
                tracks_created += song_track_result[:tracks_created]
                errors.concat(song_track_result[:errors]) if song_track_result[:errors].any?
              else
                errors << "Failed to save release: #{new_release.errors.full_messages.join(", ")}"
              end
            rescue => e
              errors << "Error processing release #{release_data["id"]}: #{e.message}"
            end

            if releases_created > 0
              success_result(data_populated: [:releases_created, :songs_created, :tracks_created])
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
            release.identifiers.find_or_create_by(
              identifier_type: :music_musicbrainz_release_id,
              value: release_data["id"]
            )

            # Create ASIN identifier if present
            if release_data["asin"].present?
              release.identifiers.find_or_create_by(
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

          # Create songs and tracks for a release from MusicBrainz media data
          # @param release [Music::Release] the release to create songs/tracks for
          # @param release_data [Hash] the MusicBrainz release data
          # @return [Hash] result with counts and errors
          def create_songs_and_tracks(release, release_data)
            songs_created = 0
            tracks_created = 0
            errors = []

            media_array = release_data["media"]
            return {songs_created: 0, tracks_created: 0, errors: []} if media_array.blank?

            media_array.each_with_index do |medium, medium_index|
              tracks_array = medium["tracks"]
              next if tracks_array.blank?

              tracks_array.each do |track_data|
                recording_data = track_data["recording"]
                next if recording_data.blank?

                begin
                  # Find or create song from recording data
                  song = find_or_create_song(recording_data)
                  songs_created += 1 if song.previously_new_record?

                  # Create track linking release to song
                  track = create_track_from_data(release, song, track_data, medium_index + 1)
                  if track.save
                    tracks_created += 1
                  else
                    errors << "Failed to save track: #{track.errors.full_messages.join(", ")}"
                  end
                rescue => e
                  errors << "Error processing track #{track_data["id"]}: #{e.message}"
                end
              end
            end

            {songs_created: songs_created, tracks_created: tracks_created, errors: errors}
          end

          # Find existing song by MusicBrainz recording ID or create new one
          # @param recording_data [Hash] the MusicBrainz recording data
          # @return [Music::Song] the found or created song
          def find_or_create_song(recording_data)
            recording_mbid = recording_data["id"]

            # Try to find existing song by MusicBrainz recording identifier
            existing_song = ::Music::Song
              .joins(:identifiers)
              .where(identifiers: {
                identifier_type: :music_musicbrainz_recording_id,
                value: recording_mbid
              })
              .first

            return existing_song if existing_song

            # Create new song from recording data
            song = ::Music::Song.new(
              title: recording_data["title"],
              duration_secs: parse_duration_secs(recording_data["length"]),
              release_year: parse_release_year(recording_data["first-release-date"]),
              notes: recording_data["disambiguation"].presence
            )

            if song.save
              # Create MusicBrainz recording identifier
              song.identifiers.create!(
                identifier_type: :music_musicbrainz_recording_id,
                value: recording_mbid
              )
            end

            song
          end

          # Create track record linking release to song
          # @param release [Music::Release] the release
          # @param song [Music::Song] the song
          # @param track_data [Hash] the MusicBrainz track data
          # @param medium_number [Integer] the medium number (1-based)
          # @return [Music::Track] the new track
          def create_track_from_data(release, song, track_data, medium_number)
            ::Music::Track.new(
              release: release,
              song: song,
              position: track_data["position"].to_i,
              medium_number: medium_number,
              length_secs: parse_duration_secs(track_data["length"]),
              notes: track_notes(track_data, song)
            )
          end

          # Parse duration from milliseconds to seconds
          # @param length_ms [String, Integer] duration in milliseconds
          # @return [Integer, nil] duration in seconds
          def parse_duration_secs(length_ms)
            return nil if length_ms.blank?

            (length_ms.to_i / 1000.0).round
          rescue
            nil
          end

          # Parse release year from date string
          # @param date_string [String] the release date (YYYY-MM-DD format)
          # @return [Integer, nil] the release year
          def parse_release_year(date_string)
            return nil if date_string.blank?

            Date.parse(date_string).year
          rescue Date::Error
            nil
          end

          # Generate track notes if track title differs from song title
          # @param track_data [Hash] the MusicBrainz track data
          # @param song [Music::Song] the associated song
          # @return [String, nil] notes about track variations
          def track_notes(track_data, song)
            track_title = track_data["title"]
            return nil if track_title.blank? || track_title == song.title

            "Track title: #{track_title}"
          end
        end
      end
    end
  end
end
