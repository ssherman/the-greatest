# frozen_string_literal: true

module Services
  module Wikidata
    # After the local Wikidata copy is rebuilt from a newer dump, re-checks the
    # recently created books and authors that found no Wikidata match: a book
    # or author the old dump did not know about may be in the new one.
    #
    # Books: created within the window, whose latest books.evidence row names no
    # QID and lists no failed source (a failed source is a different problem,
    # fixed by a normal re-gather). They start a books.book_categorize run that
    # regathers its evidence. Authors: created within the window with no
    # books_author_wikidata_qid identifier. A dry run (apply: false) only counts.
    class Recheck
      # The same pacing as the origin backfill: one start every SPACING seconds,
      # so thousands of books do not fire together.
      SPACING = ::Services::Books::Categorize::Backfill::SPACING

      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(dump_date:, apply: false)
        new(dump_date: dump_date, apply: apply).call
      end

      def initialize(dump_date:, apply:)
        @dump_date = dump_date
        @apply = apply
        @since = Rails.application.config.x.wikidata.recheck_window.ago
      end

      def call
        books = book_ids
        authors = author_ids
        if @apply
          first_slot = Time.current
          books.each_with_index { |id, index| start_book(id, first_slot + (index * SPACING).seconds) }
          authors.each_with_index { |id, index| start_author(id, first_slot + (index * SPACING).seconds) }
        end
        Result.new(success?: true, errors: [], data: {books: books.size, authors: authors.size})
      end

      private

      def book_ids
        latest = Enrichment.where(enrichable_type: "Books::Book", kind: ::Services::Books::Evidence::Gather::KIND)
          .where("NOT EXISTS (SELECT 1 FROM enrichments newer WHERE newer.enrichable_type = enrichments.enrichable_type " \
            "AND newer.enrichable_id = enrichments.enrichable_id AND newer.kind = enrichments.kind AND newer.id > enrichments.id)")
          .where("COALESCE(enrichments.facts->>'wikidata_qid', '') = ''")
          .where("COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(enrichments.facts->'sources_failed') = 'array' " \
            "THEN enrichments.facts->'sources_failed' END), 0) = 0")
        ::Books::Book.where(created_at: @since..).where(id: latest.select(:enrichable_id)).order(:id).pluck(:id)
      end

      def author_ids
        with_qid = ::Identifier.where(identifiable_type: "Books::Author", identifier_type: :books_author_wikidata_qid).select(:identifiable_id)
        ::Books::Author.where(created_at: @since..).where.not(id: with_qid).order(:id).pluck(:id)
      end

      def start_book(id, start_after)
        book = ::Books::Book.find_by(id: id)
        return if book.nil?

        ::Workflows::Books::BookCategorize.start(
          book, initiated_by: "wikidata_recheck",
          options: {"context" => "backfill", "label" => "wikidata-#{@dump_date}", "regather" => true},
          start_after: start_after
        )
      end

      # Just the Wikidata step: it applies its own result, and the VIAF and AI
      # steps are not part of re-running Wikidata resolution.
      def start_author(id, start_after)
        author = ::Books::Author.find_by(id: id)
        return if author.nil?

        ::Workflows::Books::AuthorEnrichment.start(
          author, initiated_by: "wikidata_recheck",
          options: {"refresh" => true, "allow_research" => false, "only" => %w[wikidata]},
          start_after: start_after
        )
      end
    end
  end
end
