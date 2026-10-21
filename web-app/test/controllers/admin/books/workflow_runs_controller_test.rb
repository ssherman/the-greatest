require "test_helper"

module Admin
  module Books
    class WorkflowRunsControllerTest < ActionDispatch::IntegrationTest
      include Workflows::TestDefinitionHelpers
      include Workflows::DispatchHelper

      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "renders the runs frame for a book" do
        WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 1, enrichable: @book,
          initiated_by: "test", status: :completed)
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_workflow_runs_path(@book)
        assert_response :success
      end

      test "renders the runs frame for an author, including its steps" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_workflow_runs_path(@author)
        assert_response :success
        assert_select "table tbody tr", minimum: 1
      end

      test "renders the empty state for a record with no runs" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_workflow_runs_path(@book)
        assert_response :success
        assert_select "table", count: 0
        # The frame id is the show pages' contract: without it the lazy frame never fills.
        assert_select "turbo-frame#workflow_runs_list"
      end

      test "a step waiting on its own run's step shows no link back to the page" do
        stub_workflow_dispatch
        plan_other_run
        get_path = admin_books_author_workflow_runs_path(@author)
        sign_in_as(@admin_user, stub_auth: true)
        get get_path
        assert_response :success
        assert_select "a[href=?]", admin_books_author_path(@author), count: 0
      end

      test "lists only the newest runs, newest first" do
        21.times do |i|
          WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 1, enrichable: @book,
            initiated_by: "run-#{i}", status: :completed, created_at: (30 - i).minutes.ago)
        end
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_workflow_runs_path(@book)
        assert_response :success
        assert_select "[data-testid='workflow-run']", count: 20
        assert_select "[data-testid='workflow-run']:first-of-type", text: /run-20/
        assert_select "[data-testid='workflow-run']", text: /run-0\b/, count: 0
      end

      test "a blocked step links to the record it waits on without trapping the frame" do
        stub_workflow_dispatch
        first = plan_other_run.data[:run]
        plan(waits: {a: [first.step(:c)]})
        sign_in_as(@admin_user, stub_auth: true)

        get admin_books_author_workflow_runs_path(books_authors(:king))
        assert_response :success
        assert_select "a[href=?][data-turbo-frame='_top']", admin_books_author_path(@author)
        assert_no_frame_trapped_links admin_books_author_workflow_runs_path(books_authors(:king))
      end

      test "shows the ledger rows a step wrote" do
        step = @author.then { |a| WorkflowRun.find_by!(enrichable: a).steps.first }
        Enrichment.create!(enrichable: @author, kind: "wikidata.facts", mode: :knowledge, outcome: :applied, workflow_step: step)
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_workflow_runs_path(@author)
        assert_response :success
        assert_select "[data-testid='ledger-row']", count: 1
      end

      test "redirects a signed-out visitor" do
        get admin_books_book_workflow_runs_path(@book)
        assert_redirected_to books_root_path
      end

      test "redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_author_workflow_runs_path(@author)
        assert_redirected_to books_root_path
      end

      test "lets a books domain viewer read the runs" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_author_workflow_runs_path(@author)
        assert_response :success
      end

      test "a missing book is a 404" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_workflow_runs_path(book_id: 0)
        assert_response :not_found
      end
    end
  end
end
