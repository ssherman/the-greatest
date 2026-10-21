# frozen_string_literal: true

# books.book_enrichment (spec section 6.2): the book AI step and the Amazon
# step of an import. Each wraps an existing service in an adapter under Steps.
#
# book_facts waits for the AI step of every author the import created, but
# those are other runs' steps, so the waits are passed at plan time (start)
# rather than declared here. The Goodreads project adds its edges in this
# file: `waits_on: {goodreads: :finish}` on both steps.
#
# Run options read by the steps: "force_research" (default false) and
# "author_names" (default []).
module Workflows
  module Books
    class BookEnrichment < Workflows::Definition
      workflow "books.book_enrichment"
      version 1
      target_class ::Books::Book

      add_step key: :book_facts, queue: :low, lease: 15.minutes,
        adapter: Steps::BookFacts.new

      add_step key: :amazon, queue: :serial, lease: 10.minutes,
        adapter: Steps::Amazon.new

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
            options: options.merge(author_names: author_names),
            waits: {book_facts: waited_on.map { |author_run| author_run.step(:author_facts) }},
            skips: linked_ids.empty? ? {amazon: "no_authors"} : {})
          raise ArgumentError, result.errors.join("; ") unless result.success?

          run = result.data[:run]
          # Display only: the first book run to ask keeps the author run.
          WorkflowRun.where(id: author_runs.values.map(&:id), parent_run_id: nil).update_all(parent_run_id: run.id) unless result.data[:reused]
          Workflows::Dispatcher.after_commit(result.data[:ready_steps])
          run
        end
      end
    end
  end
end
