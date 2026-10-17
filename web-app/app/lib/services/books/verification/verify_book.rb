# frozen_string_literal: true

module Services
  module Books
    module Verification
      # One book through the stages it has left (spec section 3): stage 1 when
      # it has no settled row, then whatever `stage` says. Each stage commits
      # on its own, so an error stops the book at the stage that raised and a
      # later run resumes there. Service errors propagate to Run.
      class VerifyBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        Outcome = ::Data.define(:row, :via_resolve)

        def self.call(book:, ol_client:, wc_client:, run_id:, wc_dump_date:)
          new(book, ol_client, wc_client, run_id, wc_dump_date).call
        end

        def initialize(book, ol_client, wc_client, run_id, wc_dump_date)
          @book = book
          @ol = ol_client
          @wc = wc_client
          @run_id = run_id
          @wc_dump_date = wc_dump_date
        end

        def call
          row = ::Books::Verification.find_by(book_id: @book.id)
          via_resolve = false
          if row.nil? || row.stage_work?
            applied = ApplyBook.call(book: @book, client: @ol, run_id: @run_id, cohort: Cohort.for(@book.id))
            return Result.new(success?: false, data: nil, errors: applied.errors) unless applied.success?

            row = applied.data
            via_resolve = row.via_resolve?
          end
          row.update!(run_id: @run_id) unless row.run_id == @run_id

          HarvestEditions.call(verification: row, client: @ol) if row.reload.stage_identifiers?
          ConfirmWithWorldCat.call(verification: row, client: @wc, dump_date: @wc_dump_date) if row.reload.stage_worldcat?
          Signals.call(verification: row, client: @ol) if row.reload.stage_signals?

          Result.new(success?: true, data: Outcome.new(row: row.reload, via_resolve: via_resolve), errors: [])
        end
      end
    end
  end
end
