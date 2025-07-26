# frozen_string_literal: true

module Music
  module Musicbrainz
    module Search
      class ReleaseSearch < BaseSearch
        # Get the entity type for release searches
        # @return [String] the entity type
        def entity_type
          "release"
        end

        # Get the MBID field name for releases
        # @return [String] the MBID field name
        def mbid_field
          "reid"
        end

        # Get available search fields for releases
        # @return [Array<String>] list of searchable fields
        def available_fields
          %w[
            release reid alias arid artist asin barcode catno comment
            country creditname date discids format laid label language
            mediums packaging primarytype puid quality rgid releasegroup
            script secondarytype status tag tracks
          ]
        end

        # Search for releases by title
        # @param title [String] the release title to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_title(title, options = {})
          search_by_field("release", title, options)
        end

        # Search for releases by artist MBID
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid(artist_mbid, options = {})
          search_by_field("arid", artist_mbid, options)
        end

        # Search for releases by artist name
        # @param artist_name [String] the artist name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_name(artist_name, options = {})
          search_by_field("artist", artist_name, options)
        end

        # Search for releases by release group MBID
        # @param release_group_mbid [String] the release group's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release_group_mbid(release_group_mbid, options = {})
          search_by_field("rgid", release_group_mbid, options)
        end

        # Search for releases by release group name
        # @param release_group_name [String] the release group name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release_group_name(release_group_name, options = {})
          search_by_field("releasegroup", release_group_name, options)
        end

        # Search for releases by barcode
        # @param barcode [String] the barcode (UPC/EAN)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_barcode(barcode, options = {})
          search_by_field("barcode", barcode, options)
        end

        # Search for releases by catalog number
        # @param catalog_number [String] the catalog number
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_catalog_number(catalog_number, options = {})
          search_by_field("catno", catalog_number, options)
        end

        # Search for releases by ASIN (Amazon Standard Identification Number)
        # @param asin [String] the ASIN
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_asin(asin, options = {})
          search_by_field("asin", asin, options)
        end

        # Search for releases by country code
        # @param country_code [String] the ISO country code
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_country(country_code, options = {})
          search_by_field("country", country_code, options)
        end

        # Search for releases by format (CD, Vinyl, Digital, etc.)
        # @param format [String] the release format
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_format(format, options = {})
          search_by_field("format", format, options)
        end

        # Search for releases by label MBID
        # @param label_mbid [String] the label's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_label_mbid(label_mbid, options = {})
          search_by_field("laid", label_mbid, options)
        end

        # Search for releases by label name
        # @param label_name [String] the label name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_label_name(label_name, options = {})
          search_by_field("label", label_name, options)
        end

        # Search for releases by status (Official, Promotion, Bootleg, etc.)
        # @param status [String] the release status
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_status(status, options = {})
          search_by_field("status", status, options)
        end

        # Search for releases by packaging (Jewel Case, Digipak, etc.)
        # @param packaging [String] the packaging type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_packaging(packaging, options = {})
          search_by_field("packaging", packaging, options)
        end

        # Search for releases by primary type (Album, Single, EP, etc.)
        # @param primary_type [String] the primary release type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_primary_type(primary_type, options = {})
          search_by_field("primarytype", primary_type, options)
        end

        # Search for releases by secondary type (Compilation, Soundtrack, etc.)
        # @param secondary_type [String] the secondary release type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_secondary_type(secondary_type, options = {})
          search_by_field("secondarytype", secondary_type, options)
        end

        # Search for releases by language code
        # @param language_code [String] the ISO language code
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_language(language_code, options = {})
          search_by_field("language", language_code, options)
        end

        # Search for releases by script (Latin, Cyrillic, etc.)
        # @param script [String] the script name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_script(script, options = {})
          search_by_field("script", script, options)
        end

        # Search for releases by date (YYYY, YYYY-MM, or YYYY-MM-DD)
        # @param date [String] the release date
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_date(date, options = {})
          search_by_field("date", date, options)
        end

        # Search for releases by number of mediums
        # @param medium_count [Integer] the number of mediums (discs)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_medium_count(medium_count, options = {})
          search_by_field("mediums", medium_count.to_s, options)
        end

        # Search for releases by number of tracks
        # @param track_count [Integer] the total number of tracks
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_track_count(track_count, options = {})
          search_by_field("tracks", track_count.to_s, options)
        end

        # Search for releases by tag
        # @param tag [String] the tag to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_tag(tag, options = {})
          search_by_field("tag", tag, options)
        end

        # Search for releases by alias
        # @param alias_name [String] the alias to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_alias(alias_name, options = {})
          search_by_field("alias", alias_name, options)
        end

        # Search for releases by disambiguation comment
        # @param comment [String] the disambiguation comment
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_comment(comment, options = {})
          search_by_field("comment", comment, options)
        end

        # Search for releases by credit name (how artist is credited)
        # @param credit_name [String] the credit name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_credit_name(credit_name, options = {})
          search_by_field("creditname", credit_name, options)
        end

        # Search for releases by quality (low, normal, high)
        # @param quality [String] the data quality level
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_quality(quality, options = {})
          search_by_field("quality", quality, options)
        end

        # Search for releases by disc IDs
        # @param disc_ids [String] the disc ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_disc_ids(disc_ids, options = {})
          search_by_field("discids", disc_ids, options)
        end

        # Search for releases by PUID (deprecated but still searchable)
        # @param puid [String] the PUID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_puid(puid, options = {})
          search_by_field("puid", puid, options)
        end

        # Search for releases by artist and title (common use case)
        # @param artist_name [String] the artist name
        # @param title [String] the release title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_and_title(artist_name, title, options = {})
          artist_query = build_field_query("artist", artist_name)
          title_query = build_field_query("release", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for releases by artist MBID and title (most precise search)
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param title [String] the release title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid_and_title(artist_mbid, title, options = {})
          artist_query = build_field_query("arid", artist_mbid)
          title_query = build_field_query("release", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for releases by artist with optional filters
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param filters [Hash] additional filters (format:, country:, status:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_artist_releases(artist_mbid, filters = {}, options = {})
          criteria = {arid: artist_mbid}.merge(filters)
          search_with_criteria(criteria, options)
        end

        # Search for releases within a date range
        # @param start_date [String] the start date (YYYY, YYYY-MM, or YYYY-MM-DD)
        # @param end_date [String] the end date (YYYY, YYYY-MM, or YYYY-MM-DD)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_date_range(start_date, end_date, options = {})
          query = "date:[#{start_date} TO #{end_date}]"
          search(query, options)
        end

        # Search for releases with track count in a range
        # @param min_tracks [Integer] minimum number of tracks
        # @param max_tracks [Integer] maximum number of tracks
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_track_count_range(min_tracks, max_tracks, options = {})
          query = "tracks:[#{min_tracks} TO #{max_tracks}]"
          search(query, options)
        end

        # Perform a general search query with custom Lucene syntax
        # @param query [String] the search query
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search(query, options = {})
          params = build_search_params(query, options)

          begin
            response = client.get(entity_type, params)
            process_search_response(response)
          rescue Music::Musicbrainz::Error => e
            handle_search_error(e, query, options)
          end
        end

        # Build a complex query with multiple criteria
        # @param criteria [Hash] search criteria (release:, arid:, format:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_with_criteria(criteria, options = {})
          query_parts = []

          criteria.each do |field, value|
            next if value.blank?

            if available_fields.include?(field.to_s)
              query_parts << build_field_query(field.to_s, value)
            else
              raise QueryError, "Invalid search field: #{field}"
            end
          end

          if query_parts.empty?
            raise QueryError, "At least one search criterion must be provided"
          end

          query = query_parts.join(" AND ")
          search(query, options)
        end
      end
    end
  end
end
