# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Finds an existing ::Books::Book before import and answers with a
      # Match (see FinderBase). Four sources, in order: identifiers (Open
      # Library work key, ISBN-13, ISBN-10, ASIN, Goodreads id), an exact
      # normalized title-plus-author lookup, the OpenSearch title-plus-
      # authors query, and the Open Library resolve service (or, by mode, its
      # identifier lookup, both, or neither).
      #
      # We store "Andrew Johnson" / "A Biography"; a Goodreads export says
      # "Andrew Johnson: A Biography". The two agree when the whole titles are
      # equal (titles_agree?). The part before the colon alone never proves a
      # match -- it is often a series ("Batman: ...") -- so it only finds
      # candidates for the AI.
      class Finder < DataImporters::FinderBase
        IDENTIFIER_LOOKUPS = [
          [:open_library_work_key, :books_work_openlibrary_id],
          [:isbn13, :books_work_isbn13],
          [:isbn10, :books_work_isbn10],
          [:asin, :books_work_asin],
          [:goodreads_id, :books_work_goodreads_id]
        ].freeze
        OPENSEARCH_SIZE = 5
        OPEN_LIBRARY_LIMIT = 5
        EXACT_LIMIT = 5
        # Which Open Library sources run: :resolve (the /resolve service, the
        # default), :identifiers (the fast identifier lookup only; the Goodreads
        # replay's pass one), :all (both; its pass two) or :none (no Open Library
        # source at all).
        OPEN_LIBRARY_MODES = %i[resolve identifiers all none].freeze
        # Identifier sources a "blinded" lookup trusts. Legacy's Goodreads import
        # stamped wrong ISBNs and Goodreads ids onto books, so rows from any
        # other source are ignored when this is passed as identifier_sources.
        TRUSTED_IDENTIFIER_SOURCES = (Identifier::VERIFIED_SOURCES + ["goodreads_import"]).freeze
        # Alternate-title sources a "blinded" lookup trusts. Legacy stored wrong
        # alternate titles on derived books (a "Concise" edition holding the full
        # title), so a legacy row is never evidence. A merge row is not either: the
        # merger copies the absorbed book's own title across, which for a derived
        # book is legacy's guess. An AI enrichment, an admin or a correction wrote
        # the rest.
        TRUSTED_ALTERNATE_TITLE_SOURCES = (AlternateTitle.sources.keys - %w[legacy merge]).freeze

        # open_library_client: injected by tests; nil builds the real client
        # lazily inside the Open Library sources. identifier_sources: restricts
        # the identifier lookup to rows from these Identifier sources; nil
        # trusts every row. alternate_title_sources: does the same for alternate
        # titles: given, only kept AlternateTitle rows from these sources count,
        # for the title rules and for what the AI is shown; nil keeps the
        # books_books.alternate_titles array as it is. exclude_ids: ids of books
        # no source may return (the Goodreads re-import keeps mixed books out of
        # every match); call's exclude: still drops one record.
        def initialize(open_library_client: nil, open_library: :resolve, identifier_sources: nil, alternate_title_sources: nil,
          exclude_ids: Set.new)
          raise ArgumentError, "unknown open_library mode: #{open_library.inspect}" unless OPEN_LIBRARY_MODES.include?(open_library)

          @open_library_client = open_library_client
          @open_library = open_library
          @identifier_sources = identifier_sources
          @alternate_title_sources = alternate_title_sources
          @exclude_ids = exclude_ids.to_set
        end

        def describe_candidate(candidate)
          line = super
          line = "#{line} | subtitle: #{candidate.evidence[:subtitle]}" if candidate.evidence[:subtitle].present?
          line = "#{line} | collection" if candidate.evidence[:book_kind].to_s == "collection"
          line
        end

        def describe_query(query)
          line = super
          line = "#{line} | subtitle: #{query.subtitle}" if query.subtitle.present?
          if query.series_name.present?
            line = "#{line} | series: #{[query.series_name, query.series_number && "##{query.series_number}"].compact.join(" ")}"
          end
          line = "#{line} | also credited, role unknown: #{query.context_author_names.join(", ")}" if query.context_author_names.any?
          line
        end

        # Equal titles, or equal whole titles ("title: subtitle") however each
        # side splits them. A closing series or format note is not part of the
        # title (TitleForms).
        def titles_agree?(query, record)
          return true if super

          (whole_title_keys(query) & held_title_keys(record)).any?
        end

        # The stored Open Library work keys were assigned by old matching code,
        # and some point at another book by the same author (a novel holding
        # its sequel's key). An agreeing author alone would settle that wrong
        # book as certain, so the title has to agree; otherwise the holder is
        # left to the exact rule and the AI.
        def external_accept_corroborated?(query, candidate)
          return true if query_title(query).blank? && query_creators(query).empty?

          titles_agree?(query, candidate.record)
        end

        protected

        def model_class = ::Books::Book

        def excluded_ids = @exclude_ids

        def ranking_configuration_class = ::Books::RankingConfiguration

        def creators_required? = true

        def candidate_sources(query)
          [
            DataImporters::Sources::Identifiers.new(model_class: ::Books::Book, lookups: identifier_lookups(query),
              sources: @identifier_sources),
            DataImporters::Sources::Exact.new(scope: exact_scope(query), limit: EXACT_LIMIT)
          ] + search_sources(query) + open_library_sources(query)
        end

        def domain_guidance
          "A translation, a retitled edition or an alternate spelling of the same work is the same book. " \
            "A collection or omnibus is not the same as one of the works inside it, and one volume of a series is not the series. " \
            "The words before a colon may be only a series or a character: titles that share them but whose subtitles name different stories or volumes are different books, while a descriptive subtitle that one edition has and another lacks is not a difference. " \
            "An adaptation (a graphic novel, manga, pop-up book, play or screenplay, retelling), a study guide, a summary or a commentary is a different book from the work it is based on. " \
            "Two books with the same title by different authors are different books."
        end

        # An adaptation or a guide is a different book from its source, whatever
        # the title match, search score or AI says (DerivativeWork). Applies to
        # external works too, so a member import does not create the original
        # from an Open Library adaptation record.
        def incompatible?(query, candidate)
          # A Goodreads id names one edition, so a book holding it is that edition
          # whatever its title says; dropping it would make a member's import
          # create a duplicate every time.
          return false if candidate.evidence.dig(:matched_identifier, :type).to_s == "books_work_goodreads_id"

          # An identifier-only query has nothing to compare, so it must reach its holder.
          return false if query.title.blank? && query.subtitle.blank?

          theirs = if candidate.local?
            [candidate.record.title, candidate.record.subtitle]
          else
            [candidate.evidence[:title], candidate.evidence[:subtitle]]
          end
          DerivativeWork.differ?([query.title, query.subtitle].compact_blank.join(": "), theirs.compact_blank.join(": "))
        end

        def query_creators(query) = query.author_names

        def record_creators(record) = record.authors.map(&:name)

        def record_creator_alternate_names(record) = record.authors.flat_map { |author| Array(author.alternate_names) }

        # Authors are people: initials written differently are one name.
        def creator_key(text) = ::Services::Text::PersonNameKey.call(text)

        def record_year(record) = record.first_published_year

        def record_extra_evidence(record)
          {subtitle: record.subtitle.presence, book_kind: record.book_kind, alternate_titles: record_alternate_titles(record)}
        end

        def record_alternate_titles(record)
          return Array(record.alternate_titles) unless @alternate_title_sources

          record.alternate_title_records
            .select { |row| row.status == "kept" && @alternate_title_sources.include?(row.source) }
            .map(&:title)
        end

        private

        def open_library_sources(query)
          return [] if @open_library == :none

          sources = []
          sources << OpenLibraryIdentifierSource.new(query: query, client: @open_library_client) unless @open_library == :resolve
          sources << OpenLibrarySource.new(query: query, client: @open_library_client, limit: OPEN_LIBRARY_LIMIT) unless @open_library == :identifiers
          sources
        end

        def identifier_lookups(query)
          IDENTIFIER_LOOKUPS.flat_map do |field, identifier_type|
            Array(query.public_send(field)).map { |value| [identifier_type, value] }
          end
        end

        # The search requires every word it is given in our title, which holds no
        # subtitle, so a whole title never finds a split one. The second search
        # asks for the part before the colon, without closing brackets. That part
        # is common, so it keeps only books whose author agrees: without that,
        # 91% of new colon and bracket titles reached the AI (production replay,
        # 2026-11-25).
        def search_sources(query)
          sources = [search_source(search_params(query))]
          main = TitleForms.main(query.title)
          if query.author_names.any? && main.present? && normalize(main) != normalize(query.title)
            sources << search_source(search_params(query).merge(title: main), keep: ->(book) { creators_agree?(query, book) })
          end
          sources
        end

        def search_source(params, keep: nil)
          DataImporters::Sources::OpenSearch.new(
            model_class: ::Books::Book,
            search_class: ::Search::Books::Search::BookByTitleAndAuthors,
            params: params,
            size: OPENSEARCH_SIZE,
            includes: [:authors, :identifiers],
            keep: keep
          )
        end

        # Normalized title equality (served by the lower(title) expression
        # index), joined to an author whose name keys
        # (Services::Text::PersonNameKey, GIN-indexed books_authors.name_keys)
        # meet the query's when the query names authors. A title-only query still yields
        # title matches: they are candidates for the AI, never a rule-4
        # match, because creators_required? is true for books.
        #
        # With authors, the title also reaches books that hold it split, or
        # whole, or that share only its part before the colon (TitleForms).
        # Whole-title matches come first, so a long series cannot push one out
        # of the limit.
        #
        # The filtered rows are plucked first, with no ORDER BY or LIMIT on
        # the filtered query: measured on 158k books, ORDER BY id + LIMIT 5
        # on the filtered relation makes the planner walk the primary key
        # (59 ms, every row filtered) instead of using
        # index_books_books_on_lower_title (0.01 ms). A title matches a
        # handful of rows, so plucking them all is cheap.
        def exact_scope(query)
          return ::Books::Book.none if query.title.blank?

          keys = ::Services::Text::PersonNameKey.all(query.author_names)
          titles = keys.any? ? lookup_title_keys(query) : [normalize(query.title)]
          filtered = ::Books::Book.where("LOWER(books_books.title) IN (?)", titles)
          if keys.any?
            filtered = filtered.joins(book_authors: :author)
              .where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
          end
          whole = whole_title_keys(query)
          rows = filtered.distinct.pluck(:id, :title, :subtitle)
          ids = rows.sort_by { |id, title, subtitle| [([normalize(title), whole_key(title, subtitle)] & whole).any? ? 0 : 1, id] }
            .map(&:first).first(EXACT_LIMIT)
          ::Books::Book.where(id: ids).includes(:authors, :identifiers).order(:id)
        end

        # Every title our title column may hold for the query's book.
        def lookup_title_keys(query)
          heads = [query.title, TitleForms.without_note(query.title)].map { |title| TitleForms.split(title).first }
          (whole_title_keys(query) + (heads << TitleForms.main(query.title)).map { |title| normalize(title) }).uniq
        end

        # The query's whole title, with and without a closing note, and joined to
        # its subtitle when it has one.
        def whole_title_keys(query)
          [query.title, TitleForms.without_note(query.title)]
            .flat_map { |title| [normalize(title), whole_key(title, query.subtitle)] }.compact_blank.uniq
        end

        def held_title_keys(record)
          ([record.title, *record_alternate_titles(record)].map { |title| normalize(title) } + [whole_key(record.title, record.subtitle)])
            .compact_blank.uniq
        end

        def whole_key(title, subtitle) = normalize(TitleForms.full(title, subtitle))

        def search_params(query)
          return nil if query.title.blank?

          {title: query.title, authors: query.author_names, year: query.year}
        end
      end
    end
  end
end
