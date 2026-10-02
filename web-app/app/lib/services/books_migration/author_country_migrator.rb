module Services
  module BooksMigration
    # Legacy authors.nationality_text -> books_author_countries (spec §7).
    # The legacy app used author nationality to decide a book's country, and
    # 33,678 authors carry one of 655 strings. Compounds split on "-" and
    # "/" ("Russian-American" -> Russian + American) except the names in
    # KEEP_WHOLE; each part goes through CountryLookup.from_text, which never
    # creates a country. Unmapped parts are reported with their author
    # counts (288 authors, 0.86%, 185 distinct parts; measured 2026-09-27).
    # Author ids are preserved by AuthorMigrator; one missing here (merged away in this
    # database) is skipped and counted. A repeating step: production books
    # data is truncated and migrated again before launch.
    class AuthorCountryMigrator < BulkUpsertMigrator
      KEEP_WHOLE = ["Austro-Hungarian"].freeze
      SEPARATORS = %r{[-/]}

      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::AuthorCountry"
      end

      def target_model
        ::Books::AuthorCountry
      end

      def unique_by
        :index_books_author_countries_on_author_id_and_country_id
      end

      def legacy_each(&block)
        legacy_model.where.not(nationality_text: [nil, ""]).select(:id, :nationality_text)
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def preload_context
        @author_ids = ::Books::Author.pluck(:id).to_set
        @lookup = ::Services::Books::CountryLookup.new
        @unmapped = Hash.new(0)
        @missing_authors = 0
        @seen = Set.new
      end

      def build_rows(attrs)
        author_id = attrs["id"]
        unless @author_ids.include?(author_id)
          @missing_authors += 1
          return []
        end

        parts(attrs["nationality_text"]).filter_map do |part|
          country = @lookup.from_text([part]).countries.first
          if country.nil?
            @unmapped[part] += 1
            next
          end

          key = [author_id, country.id]
          next if @seen.include?(key)

          @seen << key
          {author_id: author_id, country_id: country.id}
        end
      end

      # Protect each keep-whole name with a placeholder before splitting.
      def parts(text)
        value = text.to_s.squish
        KEEP_WHOLE.each_with_index { |whole, index| value = value.gsub(/#{Regexp.escape(whole)}/i, "\u0001#{index}\u0001") }
        value.split(SEPARATORS).map { |part| part.gsub(/\u0001(\d+)\u0001/) { KEEP_WHOLE[$1.to_i] }.squish }.reject(&:blank?)
      end

      def extra_result_data
        {unmapped: @unmapped.sort_by { |part, count| [-count, part] }.to_h, missing_authors: @missing_authors}
      end
    end
  end
end
