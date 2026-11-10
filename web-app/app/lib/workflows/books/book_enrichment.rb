# frozen_string_literal: true

# books.book_enrichment (spec section 6.2): the Goodreads step, the evidence
# step, the book AI step and the Amazon step of an import. Each wraps an existing service in an
# adapter under Steps. Version 2 added goodreads, which book_facts and amazon
# wait on (`waits_on: {goodreads: :finish}`); a run planned under version 1
# has only the other two steps and still runs. Version 3 added evidence (a
# books.evidence ledger row for the later origin and category stages), which
# waits on goodreads too; a run planned under version 2 has no evidence step
# and still runs. Version 4 added categorize (the origin judge), which waits on
# book_facts and evidence; a run planned under version 3 has no categorize step
# and still runs. Version 5 added categories (the category judge), which waits
# on categorize; a run planned under version 4 has no categories step and still
# runs.
#
# book_facts also waits for the AI step of every author the import created, but
# those are other runs' steps, so those waits are passed at plan time (start)
# rather than declared here.
#
# Run options read by the steps: "force_research" (default false) and
# "author_names" (default []).
module Workflows
  module Books
    class BookEnrichment < Workflows::Definition
      workflow "books.book_enrichment"
      version 5
      target_class ::Books::Book

      # On the goodreads_fetch capsule, one job at a time: FetchGate pacing relies on it.
      add_step key: :goodreads, queue: :goodreads_fetch, lease: 10.minutes,
        adapter: Steps::Goodreads.new

      # Gathers Wikidata, Wikipedia and WorldCat evidence for the categorize step.
      add_step key: :evidence, queue: :evidence, lease: 10.minutes, waits_on: {goodreads: :finish},
        adapter: Steps::Evidence.new

      add_step key: :book_facts, queue: :low, lease: 15.minutes, waits_on: {goodreads: :finish},
        adapter: Steps::BookFacts.new

      # Seven attempts: 30 s x 4^n backoff adds up to about 11 hours. The old job
      # retried for weeks, and amazon_enriched_at is stamped on the first pass, so
      # nothing but the ranked sweep (books:amazon_enrich_ranked) would ever try
      # a failed book again.
      add_step key: :amazon, queue: :serial, lease: 10.minutes, max_attempts: 7, waits_on: {goodreads: :finish},
        adapter: Steps::Amazon.new

      # Decides the origin country from the evidence and book_facts' answer.
      add_step key: :categorize, queue: :low, lease: 10.minutes, waits_on: {book_facts: :finish, evidence: :finish},
        adapter: Steps::Categorize.new

      # Decides genres, subjects, locations and audience; runs after categorize so
      # the two share one research call per book.
      add_step key: :categories, queue: :low, lease: 10.minutes, waits_on: {categorize: :finish, book_facts: :finish, evidence: :finish},
        adapter: Steps::Categories.new

      # Plans a book run and dispatches what is ready once the caller's
      # transaction commits. Returns the run: the new one, or the active one when
      # the book already has a run.
      #
      # Every author in new_author_ids (the ones this import created) gets an
      # author run, or joins its active one, whether or not anything waits on it:
      # a created author is enriched either way. book_facts waits only on those
      # linked to the book, and on every one of them, in any order. A created
      # author with no book_authors row holds nothing, as before.
      #
      # An active book run is returned untouched. The author runs are still
      # started, but they are not waited on and not given that run as their
      # parent: the reused run was planned for an earlier import.
      def self.start(book, initiated_by:, new_author_ids: [], author_names: [], options: {})
        ActiveRecord::Base.transaction do
          authors = ::Books::Author.where(id: new_author_ids).order(:id).to_a
          author_runs = authors.index_with { |author| AuthorEnrichment.start(author, initiated_by: initiated_by) }

          linked_ids = book.book_authors.pluck(:author_id)
          waited_on = author_runs.select { |author, _| linked_ids.include?(author.id) }.values
          result = Workflows::Planner.call(definition: self, enrichable: book, initiated_by: initiated_by,
            options: options.stringify_keys.merge("author_names" => author_names),
            waits: {book_facts: waited_on.map { |author_run| author_run.step(:author_facts) }},
            skips: linked_ids.empty? ? {goodreads: "no_authors", amazon: "no_authors"} : {})
          raise ArgumentError, result.errors.join("; ") unless result.success?

          run = result.data[:run]
          if result.data[:reused]
            Rails.logger.info "Workflows::Books::BookEnrichment: book #{book.id} already has active run #{run.id}; " \
              "planned nothing (new authors started unparented: #{authors.map(&:id).inspect})"
          else
            # Display only: the first book run to ask keeps the author run.
            WorkflowRun.where(id: author_runs.values.map(&:id), parent_run_id: nil).update_all(parent_run_id: run.id)
            pull_forward_paced_wikidata(waited_on)
          end
          Workflows::Dispatcher.after_commit(result.data[:ready_steps])
          run
        end
      end

      # A book that joins an author run planned with start_after (a backfill's
      # pacing, which can be days off) would sit in book_facts for all of it. The
      # book's own import wants the author now, so the paced Wikidata step wakes
      # at the next sweep. Only a step that never ran (attempts 0): a failure's
      # backoff waits are not pacing, and are left alone.
      def self.pull_forward_paced_wikidata(author_runs)
        now = Time.current
        WorkflowStep.where(workflow_run_id: author_runs.map(&:id), key: "wikidata", state: :waiting, attempts: 0)
          .where("run_after > ?", now).update_all(run_after: now, updated_at: now)
      end
      private_class_method :pull_forward_paced_wikidata
    end
  end
end
