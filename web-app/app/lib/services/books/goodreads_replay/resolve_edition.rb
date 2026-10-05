# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Resolves one replay edition (Goodreads import spec §12.3) and compares
      # the answer with legacy's (CompareEdition). Always verify: true:
      # legacy's own wrong identifiers sit on the books, and only corroboration
      # rejects them.
      #
      # Passes:
      # - Pass one runs the fast sources (identifiers, exact, OpenSearch, Open
      #   Library's identifier lookup).
      # - Pass two adds Open Library /resolve. It runs only for editions where
      #   pass one disagreed or found nothing.
      #
      # Never creates a book. A match that needs no further pass is recorded on
      # the edition, which warms the cache for members' imports. Three cases
      # leave the cache alone:
      # - an import already settled the edition, or is waiting on it;
      # - the match disagrees with legacy: that is a relink an admin may reject,
      #   and members' imports resolve the edition themselves.
      # A failed AI call raises (as in member resolution), so the job retries
      # instead of recording a non-answer; its decision leaves the review queue
      # first.
      class ResolveEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MatchingFailed = Class.new(StandardError)

        def self.call(edition:, pass:, finder: nil)
          new(edition: edition, pass: pass, finder: finder).call
        end

        def initialize(edition:, pass:, finder:)
          @edition = edition
          @pass = pass
          @finder = finder
        end

        def call
          query = ::Services::Books::GoodreadsImports::EditionQuery.call(@edition)
          match = finder.call(query: query, verify: true, subject: @edition)
          match.decision.update!(needs_review: false) if match.decision&.needs_review?
          raise MatchingFailed, "matching failed for Goodreads edition #{@edition.id}: #{match.reason}" if match.decided_by == :fallback

          compared = CompareEdition.call(edition: @edition, match: match, finder: finder, query: query, final: @pass == 2).data
          warm_cache(match) if match.matched? && !compared[:needs_full_pass] && !compared[:tally].key?(:disagrees)
          Result.new(success?: true, data: {match: match, needs_full_pass: compared[:needs_full_pass], tally: compared[:tally]}, errors: [])
        end

        private

        def finder
          @finder ||= ::DataImporters::Books::Book::Finder.new(open_library: (@pass == 1) ? :identifiers : :all)
        end

        def warm_cache(match)
          return if @edition.verification_pending?
          return if @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)

          @edition.update!(book: match.record, resolution: :matched, verification: :not_needed,
            match_decision: match.decision, resolved_at: Time.current)
        end
      end
    end
  end
end
