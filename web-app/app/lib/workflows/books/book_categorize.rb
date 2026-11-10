# frozen_string_literal: true

# books.book_categorize: gather evidence, then judge the origin, then the
# categories. The backfill
# and the admin Enrich button's job (Books::EnrichBookJob) start it for books
# that did not come through an import. The evidence step reuses a current,
# complete evidence row instead of gathering again.
#
# Run options read by the steps: "context", "label", "force_judge",
# "force_research" and "regather" (true: the evidence step gathers even when a
# current row exists; set by the Wikidata re-check) and "scope": which judges
# run. "origin_only" plans categories as skipped, "categories_only" plans
# categorize as skipped, "all" or absent plans both. Anything else raises.
# Version 2 added categories; a run planned under version 1 has no categories
# step and still runs.
module Workflows
  module Books
    class BookCategorize < Workflows::Definition
      workflow "books.book_categorize"
      version 2
      target_class ::Books::Book

      add_step key: :evidence, queue: :evidence, lease: 10.minutes,
        adapter: Steps::Evidence.new(reuse_fresh: true)

      add_step key: :categorize, queue: :low, lease: 10.minutes, waits_on: {evidence: :finish},
        adapter: Steps::Categorize.new

      add_step key: :categories, queue: :low, lease: 10.minutes, waits_on: {categorize: :finish, evidence: :finish},
        adapter: Steps::Categories.new

      SCOPE_SKIPS = {
        "origin_only" => {categories: "scope_origin_only"},
        "categories_only" => {categorize: "scope_categories_only"},
        "all" => {}
      }.freeze

      # Plans a run and dispatches what is ready once the caller's transaction
      # commits. Returns the run: the new one, or the active one when the book
      # already has a run.
      def self.start(book, initiated_by:, options: {}, start_after: nil)
        options = options.stringify_keys
        scope = options["scope"]
        skips = scope.nil? ? {} : SCOPE_SKIPS.fetch(scope) { raise ArgumentError, "unknown scope #{scope.inspect}" }
        result = Workflows::Planner.call(definition: self, enrichable: book, initiated_by: initiated_by,
          options: options, skips: skips, start_after: start_after)
        raise ArgumentError, result.errors.join("; ") unless result.success?

        Workflows::Dispatcher.after_commit(result.data[:ready_steps])
        result.data[:run]
      end
    end
  end
end
