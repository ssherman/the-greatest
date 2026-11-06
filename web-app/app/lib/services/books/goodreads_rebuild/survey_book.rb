# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Records the stage one survey for one derived book (rebuild spec §4):
      # the editions its export rows name, grouped into works, and whether our
      # title and authors agree with them. Reads only; writes only the book's
      # Books::RebuildBookSurvey row, in place on a re-survey. The caller
      # passes the book's rows, preloaded with their editions (Survey loads a
      # batch at a time).
      class SurveyBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        # evidence: survey pass 2's evidence by edition id. Survey passes a
        # batch's worth; nil loads this book's.
        def self.call(book:, rows:, evidence: nil)
          new(book, rows, evidence).call
        end

        def initialize(book, rows, evidence)
          @book = book
          @rows = rows.select(&:goodreads_edition)
          @evidence = evidence
        end

        def call
          editions = @rows.map(&:goodreads_edition).uniq(&:id)
          row_counts = @rows.map(&:goodreads_edition_id).tally
          evidence = @evidence || ::Books::RebuildEditionEvidence.for_editions(editions)
          groups = GroupEditions.call(editions: editions, row_counts: row_counts, evidence: evidence)
          identity = CompareIdentity.call(book: @book, groups: groups, editions_by_id: editions.index_by(&:id))

          survey = ::Books::RebuildBookSurvey.find_or_initialize_by(book: @book)
          survey.update!(classification: GroupEditions.classify(groups), groups: groups, edition_count: editions.size,
            row_count: @rows.size, surveyed_at: Time.current, **identity)
          Result.new(success?: true, data: {survey: survey}, errors: [])
        end
      end
    end
  end
end
