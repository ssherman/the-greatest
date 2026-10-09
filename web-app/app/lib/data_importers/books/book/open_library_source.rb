# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # The books finder's external source: one POST /resolve on the Open
      # Library data service. Every returned work becomes a candidate with
      # the service's verdict, score, margin and rules as evidence; a work
      # whose key (or a key it redirects from) a local book already holds
      # becomes one candidate per holder, carrying both halves, so the
      # rules can treat "the service accepted a key we hold" as identity
      # evidence and two holders as a suspected pair. The whole Resolution
      # is kept for the provider (FinderBase copies it onto the match).
      #
      # Not a `Sources` module on purpose: DataImporters::Sources is the
      # shared one and a nested module of the same name would shadow it.
      class OpenLibrarySource
        attr_reader :resolution

        def initialize(query:, client: nil, limit: 5)
          @query = query
          @client = client
          @limit = limit
          @resolution = nil
        end

        def name
          :open_library
        end

        # Raises whatever the client raises (circuit open, timeout, HTTP,
        # parse): the finder records that as a failed source.
        def call
          @resolution = client.resolve(**resolve_args)
          returned = @resolution.candidates.flat_map { |candidate| candidates_for(candidate) }
          returned + duplicate_holders(returned)
        end

        # Lazy: building the default client constructs a CircuitBreaker
        # against REDIS_POOL, and a test that injects its own must never
        # trigger that.
        def client
          @client ||= ::Books::OpenLibrary::Client.new
        end

        private

        def resolve_args
          {
            title: @query.title.to_s,
            subtitle: @query.subtitle,
            author_names: @query.author_names,
            year: @query.year,
            isbn13: @query.isbn13,
            isbn10: @query.isbn10,
            asin: @query.asin,
            goodreads_id: @query.goodreads_id,
            existing_ol_key: @query.open_library_work_key,
            limit: @limit
          }
        end

        def candidates_for(ol_candidate)
          work = ol_candidate.record
          external = {
            external_verdict: ol_candidate.verdict,
            external_score: ol_candidate.score,
            external_margin: ol_candidate.margin,
            external_rules: ol_candidate.rules
          }
          holders = local_holders([ol_candidate.work_key, *ol_candidate.redirect_sources, *Array(work&.redirected_from)])

          if holders.empty?
            [build(ol_candidate, external.merge(title: work&.title, creators: Array(work&.author_names), year: year_of(work)))]
          else
            evidence = external.merge(external_title: work&.title, external_creators: Array(work&.author_names), external_year: year_of(work))
            duplicate_of = duplicate_of(ol_candidate.work_key)
            evidence[:external_duplicate_of] = duplicate_of if duplicate_of
            holders.map { |book| build(ol_candidate, evidence, record: book) }
          end
        end

        # The accepted work's key when this work is one of its duplicates. A
        # duplicate usually ranks just below the work it duplicates, so it is
        # returned as a candidate of its own far more often than it is not.
        def duplicate_of(work_key)
          accepted = @resolution.accepted
          accepted.work_key if accepted && @resolution.decision.duplicates.include?(work_key)
        end

        def build(ol_candidate, evidence, record: nil)
          Candidate.new(
            record: record,
            external_key: ol_candidate.work_key,
            external_source: :open_library,
            external_record: ol_candidate,
            sources: [:open_library],
            scores: {open_library: ol_candidate.score},
            evidence: evidence
          )
        end

        # Local books holding a duplicate of the accepted work (another work
        # in its duplicate cluster) or an old key that redirects to one. Each
        # is a candidate under the key it actually holds, with the accepted
        # work's facts as evidence and no verdict: a duplicate is sometimes a
        # different text, so holding one is never the service accepting the
        # book. Their presence still stops rule 5 from creating a book we
        # may already have, and `external_duplicate_of` groups them with the
        # accepted work's holders as suspected pairs. Books already returned
        # as a holder of some candidate are left alone. So are books holding
        # the accepted work, or one of its duplicates, as a duplicate-type key
        # (saved by the Open Library key backfill).
        def duplicate_holders(returned)
          accepted = @resolution.accepted
          decision = @resolution.decision
          return [] unless accepted

          keys = (decision.duplicates + decision.duplicate_redirect_sources).uniq - [accepted.work_key]
          # Work keys of the duplicates, plus duplicate-type keys (the OL key
          # backfill) of the accepted work or its duplicates.
          holdings = holdings_of(keys, work_key_type)
            .merge(holdings_of([accepted.work_key, *keys], duplicate_key_type)) { |_id, ours, theirs| (ours + theirs).uniq }
          return [] if holdings.empty?

          seen = returned.filter_map { |candidate| candidate.record&.id }
          work = accepted.record
          evidence = {
            external_duplicate_of: accepted.work_key, external_score: accepted.score,
            external_title: work&.title, external_creators: Array(work&.author_names), external_year: year_of(work)
          }
          ::Books::Book.where(id: holdings.keys - seen).order(:id).map do |book|
            Candidate.new(
              record: book,
              external_key: holdings.fetch(book.id).min,
              external_source: :open_library,
              sources: [:open_library],
              scores: {open_library: accepted.score},
              evidence: evidence
            )
          end
        end

        # Local books holding any of these Open Library work keys.
        def local_holders(keys)
          ::Books::Book
            .joins(:identifiers)
            .where(identifiers: {identifier_type: work_key_type, value: keys.compact_blank.uniq})
            .distinct
            .order(:id)
            .to_a
        end

        # book id -> the keys (of `keys`) it holds as `type`.
        def holdings_of(keys, type)
          return {} if keys.empty?

          ::Identifier
            .where(identifiable_type: "Books::Book", identifier_type: type, value: keys)
            .pluck(:identifiable_id, :value)
            .group_by(&:first)
            .transform_values { |rows| rows.map(&:last) }
        end

        def duplicate_key_type
          ::Identifier.identifier_types[:books_work_openlibrary_duplicate_id]
        end

        def work_key_type
          ::Identifier.identifier_types[:books_work_openlibrary_id]
        end

        # 89% of works carry no declared year; the earliest edition year is
        # the next best approximation of first publication.
        def year_of(work)
          evidence = work&.year_evidence || {}
          evidence[:declared_year] || evidence[:min_edition_year]
        end
      end
    end
  end
end
