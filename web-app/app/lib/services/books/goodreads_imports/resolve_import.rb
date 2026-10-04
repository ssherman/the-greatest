# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Resolves every edition an import's rows name, once each, then sets
      # the import's counters from what is now true (Goodreads import spec §5,
      # §13). Safe to run again: resolved editions are reused, and the
      # counters are recomputed rather than incremented, so a retry neither
      # double-counts nor loses anything. ai_calls_count is the exception: it
      # counts calls as they happen (ResolveEdition).
      #
      # One failing edition never stops the import: its rows carry the error
      # and the edition stays unresolved for the next run, which clears the
      # error on success. Postgres errors re-raise.
      class ResolveImport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

        def self.call(import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(import: import, finder: finder, importer: importer).call
        end

        def initialize(import:, finder:, importer:)
          @import = import
          @finder = finder || ::DataImporters::Books::Book::Finder.new
          @importer = importer
        end

        def call
          outcomes = Hash.new(0)
          ::Books::GoodreadsEdition.where(id: edition_ids).order(:id).each do |edition|
            outcomes[resolve(edition)] += 1
          end
          recount
          Result.new(success?: true, data: {import: @import, outcomes: outcomes}, errors: [])
        end

        private

        def edition_ids
          @edition_ids ||= @import.rows.where.not(goodreads_edition_id: nil).distinct.pluck(:goodreads_edition_id)
        end

        def resolve(edition)
          result = ResolveEdition.call(edition: edition, import: @import, finder: @finder, importer: @importer)
          rows_for(edition).where.not(error: nil).update_all(error: nil)
          result.data[:outcome]
        rescue *POSTGRES_ERRORS
          raise
        rescue => e
          Rails.logger.error("#{self.class.name}: Goodreads edition #{edition.id} failed: #{e.class}: #{e.message}")
          rows_for(edition).update_all(error: "resolution failed: #{e.class}: #{e.message}")
          :failed
        end

        def rows_for(edition)
          @import.rows.where(goodreads_edition_id: edition.id)
        end

        # created: books this import made that still exist and that its
        # editions still link to; a created book later merged into another, or
        # deleted and made again, counts once as what it is now. matched: every
        # other linked edition, including books another import created.
        # flagged: linked decisions still waiting for review.
        def recount
          editions = ::Books::GoodreadsEdition.where(id: edition_ids)
          created_book_ids = ::Books::Book
            .where(id: @import.records.created.where(record_type: "Books::Book").select(:record_id))
            .where(id: editions.select(:book_id))
            .pluck(:id)
          @import.update!(
            created_count: created_book_ids.size,
            matched_count: editions.where.not(book_id: nil).where.not(book_id: created_book_ids).count,
            parked_count: editions.parked.count,
            flagged_count: editions.joins(:match_decision).merge(::MatchDecision.needing_review).count
          )
        end
      end
    end
  end
end
