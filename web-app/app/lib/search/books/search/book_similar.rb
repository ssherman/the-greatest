# frozen_string_literal: true

module Search
  module Books
    module Search
      # One OpenSearch query returning books similar to a given book, scored from
      # shared genre, subject and location categories.
      #
      # Every category match is its own `term` clause rather than one `terms`
      # clause, and that is load-bearing -- but not for the reason it looks like
      # at a glance. The design intent was per-term IDF (a shared rare category
      # like "Existentialist fiction" outscoring a shared common one like
      # "Fiction"). `_explain` against a real query shows that is NOT what
      # happens: the `keyword` fields these clauses target (genre_category_ids
      # etc.) are indexed with no per-document term frequency and no norms, so
      # OpenSearch/Lucene rewrites a `term` query on them to
      # `ConstantScore(term)^boost` regardless of the term's document frequency
      # across the index -- confirmed independently against the dev corpus, not
      # just this test index. Rarity still matters, just earlier: it drives which
      # categories get selected (rarest-first sort, the max_category_item_count
      # ceiling in select_categories), not how a selected match is scored.
      #
      # The per-term-vs-terms choice is still load-bearing for a different,
      # precise reason: N separate `term` clauses in `should` each contribute
      # their own constant `boost`, so N of them sum to N x boost -- sharing
      # four genres scores 4x a single shared genre. A single `terms` clause,
      # by contrast, contributes its boost exactly ONCE no matter how many of
      # its values matched, collapsing "shared four genres" and "shared one
      # genre" into the identical score. Do not "simplify" these into a terms
      # query.
      class BookSimilar < ::Search::Base::Search
        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(book, options = {})
          opts = Rails.application.config.x.book_similarity.merge(options)
          categories = categories_by_type(book, opts)
          return [] if categories.values.all?(&:empty?)

          response = search(build_query_definition(book, categories, opts))
          extract_hits_with_scores(response)
        end

        # => {"genre" => [Category, ...], "subject" => [...], "location" => [...]}
        def self.categories_by_type(book, opts)
          active = book.categories.select { |c| c.deleted == false }

          # The model's constant, not a copy: if the two lists drift, the model
          # indexes a category type this query never asks about, silently.
          by_type = ::Books::Book::SIMILARITY_CATEGORY_TYPES.index_with do |type|
            select_categories(active.select { |c| c.category_type == type }, opts)
          end

          restore_rarest_genre_if_ceiling_emptied_genres(active, by_type, opts)
        end

        # Rarest first, because a rare category says more about a book than a
        # common one. The `c.id` tie-break is explicit so ordering is
        # deterministic. Purely a per-type filter -- it does not know or care
        # about the other two types, on purpose (see
        # restore_rarest_genre_if_ceiling_emptied_genres, which is the only
        # place cross-type/genre-specific reasoning belongs).
        def self.select_categories(scoped, opts)
          by_rarity = scoped.sort_by { |c| [c.item_count.to_i, c.id] }
          return by_rarity.first(opts[:max_categories_per_type]) unless opts[:drop_common_categories]

          kept = by_rarity.reject { |c| c.item_count.to_i > opts[:max_category_item_count] }
          kept.first(opts[:max_categories_per_type])
        end

        # Load-bearing guard, genre-specific and deliberately indifferent to
        # subject/location: require_genre_match depends solely on
        # categories["genre"], and its own `categories["genre"].any?` check
        # silently disables the requirement rather than matching nothing when
        # genre comes back empty. An aggressive max_category_item_count that
        # empties every genre on this book would otherwise turn off the genre
        # gate entirely -- letting a novel match a history book purely on a
        # shared location, which is exactly what require_genre_match exists to
        # prevent. Measured against the dev corpus: 6,405 books (5% of the
        # 126,218 with genres) have every genre above the default 25k ceiling
        # while a subject or location survives -- for exactly those books, a
        # cross-type guard (fire only when EVERY type empties) would drop the
        # genre gate and let this defect back in. Whether subject or location
        # also emptied is irrelevant here on purpose: a surviving subject or
        # location does not make dropping every genre any safer.
        def self.restore_rarest_genre_if_ceiling_emptied_genres(active, by_type, opts)
          return by_type unless opts[:drop_common_categories]
          return by_type if by_type["genre"].any?

          rarest_genre = active.select { |c| c.category_type == "genre" }.min_by { |c| [c.item_count.to_i, c.id] }
          by_type["genre"] = [rarest_genre] if rarest_genre
          by_type
        end

        def self.build_query_definition(book, categories, opts)
          filter = [{term: {ranked: true}}]

          # The genre clauses appear twice on purpose. `filter` clauses contribute
          # no score, so requiring a genre match needs its own unscored bool here,
          # while the scored genre clauses stay in `should` with their boost.
          if opts[:require_genre_match] && categories["genre"].any?
            filter << {
              bool: {
                should: categories["genre"].map { |c| {term: {genre_category_ids: c.id.to_s}} },
                minimum_should_match: 1
              }
            }
          end

          should = boosted_terms(categories["genre"], :genre_category_ids, opts[:genre_boost]) +
            boosted_terms(categories["subject"], :subject_category_ids, opts[:subject_boost]) +
            boosted_terms(categories["location"], :location_category_ids, opts[:location_boost])

          if book.original_language_id.present?
            should << {term: {original_language_id: {value: book.original_language_id.to_s, boost: opts[:language_boost]}}}
          end

          if book.first_published_year.present?
            should << {
              range: {
                first_published_year: {
                  gte: book.first_published_year - opts[:era_years],
                  lte: book.first_published_year + opts[:era_years],
                  boost: opts[:era_boost]
                }
              }
            }
          end

          book.authors.each do |author|
            should << {term: {author_ids: {value: author.id.to_s, boost: opts[:author_boost]}}}
          end

          excluded = [book.id.to_s]
          excluded.concat(same_series_book_ids(book)) if opts[:exclude_same_series]

          bool = {
            filter: filter,
            must_not: [{ids: {values: excluded}}],
            should: should,
            # Explicit because a bool carrying a `filter` defaults its should-minimum to 0.
            minimum_should_match: 1
          }

          {
            size: opts[:limit] * opts[:over_fetch],
            min_score: opts[:min_score],
            _source: false,
            query: wrap_in_normalization(bool, opts)
          }
        end

        # Turns the raw sum into something closer to cosine similarity: without it
        # a book tagged with 40 categories has 40 chances to score and outranks a
        # tighter match with 6. Documents indexed before the similarity fields
        # existed (no doc value for similarity_category_count) divide by 1 rather
        # than erroring.
        #
        # `boost_mode: "divide"` is NOT a real OpenSearch/Lucene CombineFunction --
        # only multiply/replace/sum/avg/max/min exist -- so field_value_factor
        # cannot express "score / sqrt(count)" directly. script_score plus
        # `boost_mode: "replace"` computes the division ourselves and installs it
        # as the final score outright, rather than the function_score default of
        # multiplying it into the query score again.
        def self.wrap_in_normalization(bool, opts)
          return {bool: bool} unless opts[:normalize_by_category_count]

          {
            function_score: {
              query: {bool: bool},
              script_score: {
                script: {
                  source: "_score / Math.sqrt(doc['similarity_category_count'].size() == 0 ? 1 : doc['similarity_category_count'].value)"
                }
              },
              boost_mode: "replace"
            }
          }
        end

        def self.boosted_terms(categories, field, boost)
          categories.map { |c| {term: {field => {value: c.id.to_s, boost: boost}}} }
        end

        def self.same_series_book_ids(book)
          ::Books::SeriesBook
            .where(series_id: ::Books::SeriesBook.where(book_id: book.id).select(:series_id))
            .where.not(book_id: book.id)
            .pluck(:book_id)
            .map(&:to_s)
        end
      end
    end
  end
end
