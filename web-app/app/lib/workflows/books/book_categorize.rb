# frozen_string_literal: true

# books.book_categorize: gather evidence, then judge the origin. The backfill
# and the admin Enrich button's job (Books::EnrichBookJob) start it for books
# that did not come through an import. The evidence step reuses a current,
# complete evidence row instead of gathering again.
#
# Run options read by the steps: "context", "label", "force_judge",
# "force_research" and "regather" (true: the evidence step gathers even when a
# current row exists; set by the Wikidata re-check).
module Workflows
  module Books
    class BookCategorize < Workflows::Definition
      workflow "books.book_categorize"
      version 1
      target_class ::Books::Book

      add_step key: :evidence, queue: :evidence, lease: 10.minutes,
        adapter: Steps::Evidence.new(reuse_fresh: true)

      add_step key: :categorize, queue: :low, lease: 10.minutes, waits_on: {evidence: :finish},
        adapter: Steps::Categorize.new

      # Plans a run and dispatches what is ready once the caller's transaction
      # commits. Returns the run: the new one, or the active one when the book
      # already has a run.
      def self.start(book, initiated_by:, options: {}, start_after: nil)
        result = Workflows::Planner.call(definition: self, enrichable: book, initiated_by: initiated_by,
          options: options.stringify_keys, start_after: start_after)
        raise ArgumentError, result.errors.join("; ") unless result.success?

        Workflows::Dispatcher.after_commit(result.data[:ready_steps])
        result.data[:run]
      end
    end
  end
end
