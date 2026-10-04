# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Resolves one Goodreads edition (Goodreads import spec §5):
      #
      # 1. Cache: an edition already resolved to a book that still exists (or
      #    parked) is reused. The merger moves editions, so merges are
      #    followed; a deleted book nullifies book_id and the edition is
      #    resolved again.
      # 2. Finder: the full books finder, with the edition as its subject and
      #    the series and other credited names as AI context.
      # 3. Outcome: a match links (the finder flags medium, low and fallback
      #    decisions). No match creates a provisional book through CreateBook.
      #    An AI "none of these" creates too, and is flagged here; nothing
      #    ever falls back to the top search hit. A failed AI call (the
      #    finder's fallback decision) is not an answer: it raises, and the
      #    edition waits for the next run instead of creating a duplicate of a
      #    book the AI never got to judge.
      #
      # A decision that does not end up as the edition's (the run failed, or
      # another import resolved the edition first) is taken out of the review
      # queue, so a retry never leaves an orphan flag behind.
      #
      # Every AI call is counted on the import. Nothing caps them.
      class ResolveEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MatchingFailed = Class.new(StandardError)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

        def self.call(edition:, import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(edition: edition, import: import, finder: finder, importer: importer).call
        end

        def initialize(edition:, import:, finder:, importer:)
          @edition = edition
          @import = import
          @finder = finder || ::DataImporters::Books::Book::Finder.new
          @importer = importer
        end

        def call
          return done(:cached) if settled?

          match = @finder.call(query: query, subject: @edition)
          @import.increment!(:ai_calls_count) if ai_call?(match.decision)
          outcome = resolve(match)
          supersede_unused(match.decision)
          done(outcome)
        rescue *POSTGRES_ERRORS
          raise
        rescue
          supersede(match&.decision)
          raise
        end

        private

        def resolve(match)
          if match.matched?
            @edition.update!(book: match.record, resolution: :matched, verification: :not_needed,
              match_decision: match.decision, resolved_at: Time.current)
            return :matched
          end
          if match.decided_by == :fallback
            raise MatchingFailed, "matching failed for Goodreads edition #{@edition.id}: #{match.reason}"
          end

          match.decision&.update!(needs_review: true) if match.decided_by == :ai
          CreateBook.call(edition: @edition, import: @import, match: match, importer: @importer).data[:outcome]
        end

        def supersede(decision)
          decision.update!(needs_review: false) if decision&.needs_review?
        end

        # Every flagged decision about this edition up to this run's own,
        # except the one the edition now holds: this run's if it went unused,
        # and any a crashed earlier run left behind (a killed worker never
        # reaches the rescue). Later ids belong to another import still
        # resolving the same edition, and are its to settle.
        def supersede_unused(decision)
          return if decision.nil?

          ::MatchDecision.needing_review.where(subject: @edition).where(id: ..decision.id)
            .where.not(id: @edition.match_decision_id).update_all(needs_review: false, updated_at: Time.current)
        end

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def query
          ::DataImporters::Books::Book::ImportQuery.new(
            title: @edition.title,
            author_names: [@edition.primary_author],
            year: @edition.original_publication_year || @edition.year_published,
            isbn13: [@edition.isbn13],
            isbn10: [@edition.isbn10],
            goodreads_id: [@edition.goodreads_book_id.to_s],
            series_name: @edition.series_name,
            series_number: @edition.series_number,
            context_author_names: @edition.additional_authors
          )
        end

        # A fallback decision only comes from an AI call that failed, which
        # was still a call.
        def ai_call?(decision)
          decision.present? && (decision.ai_chat_id.present? || decision.decided_by_ai? || decision.decided_by_fallback?)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
