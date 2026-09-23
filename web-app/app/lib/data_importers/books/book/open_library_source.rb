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
          @resolution.candidates.flat_map { |candidate| candidates_for(candidate) }
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
          holders = local_holders(ol_candidate.work_key, work)

          if holders.empty?
            [build(ol_candidate, external.merge(title: work&.title, creators: Array(work&.author_names), year: year_of(work)))]
          else
            evidence = external.merge(external_title: work&.title, external_creators: Array(work&.author_names), external_year: year_of(work))
            holders.map { |book| build(ol_candidate, evidence, record: book) }
          end
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

        # Local books holding this work's key, or a key the service says
        # redirects to it (a stale local key still names the same work).
        def local_holders(work_key, work)
          keys = ([work_key] + Array(work&.redirected_from)).compact_blank.uniq
          ::Books::Book
            .joins(:identifiers)
            .where(identifiers: {identifier_type: ::Identifier.identifier_types[:books_work_openlibrary_id], value: keys})
            .distinct
            .order(:id)
            .to_a
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
