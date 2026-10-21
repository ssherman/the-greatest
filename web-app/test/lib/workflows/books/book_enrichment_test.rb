# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    class BookEnrichmentTest < ActiveSupport::TestCase
      setup do
        # got is linked to king; garnett is linked below. bachman stays unlinked.
        @book = books_books(:got)
        @a = books_authors(:king)
        @b = books_authors(:garnett)
        ::Books::BookAuthor.create!(book: @book, author: @b, position: 2, role: :author)
        stub_workflow_dispatch
      end

      def start(book = @book, **args)
        BookEnrichment.start(book, initiated_by: "test", **args)
      end

      def author_run(author)
        WorkflowRun.running.find_by!(workflow: "books.author_enrichment", enrichable: author)
      end

      # Claims and finishes the author's AI step as a worker would. The step is
      # forced ready: the chain before it is not what these tests are about.
      def finish_author_facts(author, outcome: Workflows::Outcome.succeeded("done"))
        step = author_run(author).step(:author_facts)
        step.update_columns(state: WorkflowStep.states[:ready])
        claimed = Workflows::Coordinator.claim(step.id, token: "t-#{author.id}")
        Workflows::Coordinator.finish(claimed, token: "t-#{author.id}", outcome: outcome)
      end

      # The fixture run on Tolstoy has only a wikidata step; give it the AI step
      # a real author run would have.
      def tolstoy_author_facts(**attributes)
        workflow_runs(:tolstoy_author_run).steps.create!({key: "author_facts", queue: "author_chain", max_attempts: 3,
                                                          lease_seconds: 900, state: :blocked}.merge(attributes))
      end

      def prerequisites_of(step)
        WorkflowDependency.where(step: step).map(&:prerequisite_step)
      end

      test "is registered as books.book_enrichment version 1 on books, with book_facts and amazon" do
        assert_equal [BookEnrichment, "books.book_enrichment", 1, ::Books::Book], [
          Workflows::Registry.fetch("books.book_enrichment"), BookEnrichment.workflow, BookEnrichment.version, BookEnrichment.target_class
        ]
        assert_equal %i[book_facts amazon], BookEnrichment.steps.map(&:key)
        assert_equal [:low, :serial], BookEnrichment.steps.map(&:queue)
        assert_equal [15.minutes, 10.minutes], BookEnrichment.steps.map(&:lease)
        assert_equal [{}, {}], BookEnrichment.steps.map(&:waits_on)
      end

      test "a book with no new authors makes book_facts and amazon ready at once" do
        run = start

        assert_equal %w[ready ready], %w[book_facts amazon].map { run.step(it).state }
      end

      test "start dispatches the ready steps after commit" do
        Workflows::Dispatcher.unstub(:dispatch)
        Workflows::Dispatcher.expects(:dispatch).with { |steps| steps.map(&:key).sort == %w[amazon book_facts] }

        start
      end

      test "the options and author names travel on the run" do
        run = start(author_names: ["Stephen King"], options: {force_research: true})

        assert_equal({"force_research" => true, "author_names" => ["Stephen King"]}, run.options)
      end

      test "book_facts waits for every new linked author, in either completion order" do
        run = start(new_author_ids: [@a.id, @b.id])
        assert_equal %w[blocked ready], %w[book_facts amazon].map { run.step(it).state }

        finish_author_facts(@b)
        assert_equal "blocked", run.step(:book_facts).reload.state

        finish_author_facts(@a)
        assert_equal "ready", run.step(:book_facts).reload.state
      end

      test "simultaneous author completion makes book_facts ready once" do
        run = start(new_author_ids: [@a.id, @b.id])
        finish_author_facts(@a)
        finish_author_facts(@b)

        assert_equal "ready", run.step(:book_facts).reload.state
        assert_equal [[], []], [@a, @b].map { Workflows::Coordinator.advance(author_run(it).step(:author_facts)) }
      end

      test "the new authors' runs are started and tagged with the book run as parent" do
        run = start(new_author_ids: [@a.id, @b.id])

        assert_equal [run.id, run.id], [@a, @b].map { author_run(it).parent_run_id }
      end

      test "a created author not linked to the book gets a run but holds nothing" do
        unlinked = books_authors(:bachman)
        run = start(new_author_ids: [unlinked.id])

        assert_equal "ready", run.step(:book_facts).state
        assert_equal run.id, author_run(unlinked).parent_run_id
      end

      test "joins an author's active run instead of planning another" do
        existing = workflow_runs(:tolstoy_author_run)
        facts = tolstoy_author_facts
        tolstoy = books_authors(:tolstoy)
        book = books_books(:war_and_peace)

        assert_no_difference -> { WorkflowRun.where(workflow: "books.author_enrichment").count } do
          run = start(book, new_author_ids: [tolstoy.id])

          assert_equal "blocked", run.step(:book_facts).state
          assert_equal [facts], prerequisites_of(run.step(:book_facts))
        end
        assert_equal run_ids(existing), run_ids(author_run(tolstoy))
      end

      test "an author whose AI step is already released does not hold the book" do
        tolstoy_author_facts(state: :succeeded, outcome: "done", released_at: Time.current, finished_at: Time.current)

        run = start(books_books(:war_and_peace), new_author_ids: [books_authors(:tolstoy).id])

        assert_equal "ready", run.step(:book_facts).state
      end

      test "a book with no book_authors plans amazon skipped as no_authors" do
        bare = books_books(:crime_and_punishment)
        assert bare.book_authors.none?

        run = start(bare, author_names: ["Fyodor Dostoevsky"])

        assert_equal [["skipped", "no_authors"], "ready"], [[run.step(:amazon).state, run.step(:amazon).outcome], run.step(:book_facts).state]
      end

      test "book_facts still runs after an author's AI step failed" do
        run = start(new_author_ids: [@a.id])
        step = author_run(@a).step(:author_facts)
        step.update_columns(state: WorkflowStep.states[:running], lease_token: "dead", attempts: 2, lease_expires_at: 1.minute.from_now)

        Workflows::Coordinator.fail(step, token: "dead", error: StandardError.new("boom"))

        assert_equal ["failed", "ready"], [step.reload.state, run.step(:book_facts).reload.state]
      end

      test "a deleted author releases the waiting book (via recovery)" do
        run = start(new_author_ids: [@a.id])
        author_run(@a).update_columns(enrichable_id: 0)

        Workflows::Recovery.call

        assert_equal "ready", run.step(:book_facts).reload.state
      end

      test "an active book run is returned as is: no wait is added and no author run is re-parented" do
        first = start
        second = start(new_author_ids: [@a.id])

        assert_equal first.id, second.id
        assert_nil author_run(@a).parent_run_id
        assert_empty prerequisites_of(second.step(:book_facts))
      end

      test "an author run that already has a parent keeps it" do
        other_book_run = start(books_books(:clash), new_author_ids: [@a.id])
        run = start(new_author_ids: [@a.id])

        assert_equal other_book_run.id, author_run(@a).parent_run_id
        assert_equal "blocked", run.step(:book_facts).state
      end

      def run_ids(*runs) = runs.map(&:id)
    end
  end
end
