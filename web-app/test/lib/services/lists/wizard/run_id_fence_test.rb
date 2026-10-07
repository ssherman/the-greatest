# frozen_string_literal: true

require "test_helper"

# A job acts only while its step's current run id is its own (books list
# wizard: a retried step must not be raced by the run it replaced).
module Services
  module Lists
    module Wizard
      class RunIdFenceTest < ActiveSupport::TestCase
        include ListWizardHelper

        Core = ::Services::Lists::Wizard::Core
        Result = ::Services::Lists::Wizard::Books::Adapter::Result

        setup do
          @list = wizard_list
          @adapter = ::Services::Lists::Wizard::Books::Adapter.new
          Core::Adapters.stubs(:for).returns(@adapter)
        end

        def start(step, run_id, status: "running")
          @list.wizard_manager.write_step!(step: step, status: status, metadata: {"run_id" => run_id})
        end

        def parsed(*rows)
          @adapter.stubs(:parse).returns(Result.new(success?: true, data: rows, errors: []))
        end

        def row(title) = {"rank" => nil, "title" => title, "subtitle" => nil, "authors" => [], "year" => nil}

        def create_row(position, title)
          wizard_row(@list, position: position, title: title, wizard: {bucket: "create", ol_work_key: "OL#{position}W"})
        end

        # ---- Parse ------------------------------------------------------------

        test "a stale ParseJob deletes and inserts nothing and writes no status" do
          old = wizard_row(@list, position: 1, title: "Old Row")
          start("parse", "new-run")
          @adapter.expects(:parse).never
          before = @list.reload.wizard_state

          ::Lists::Wizard::ParseJob.new.perform(@list.id, "old-run")

          assert ::ListItem.exists?(old.id)
          assert_equal 1, @list.list_items.count
          assert_equal before, @list.reload.wizard_state
        end

        test "a parse superseded during the AI call replaces nothing and completes nothing" do
          old = wizard_row(@list, position: 1, title: "Old Row")
          start("parse", "run-1")
          manager = @list.wizard_manager
          emma = row("Emma")
          @adapter.define_singleton_method(:parse) do |list, **|
            manager.write_step!(step: "parse", status: "running", metadata: {"run_id" => "run-2"})
            Result.new(success?: true, data: [emma], errors: [])
          end

          Core::ParseRows.call(list: ::List.find(@list.id), adapter: @adapter, run_id: "run-1")

          assert ::ListItem.exists?(old.id)
          assert_equal ["Old Row"], @list.list_items.reload.map { |item| item.metadata["title"] }
          assert_equal ["running", "run-2"], [@list.reload.wizard_manager.step_status("parse"), @list.wizard_manager.step_metadata("parse")["run_id"]]
        end

        test "the current run parses as before" do
          start("parse", "run-1")
          parsed(row("Emma"))

          assert_equal 1, Core::ParseRows.call(list: @list, adapter: @adapter, run_id: "run-1")
          assert_equal "completed", @list.reload.wizard_manager.step_status("parse")
        end

        # ---- Match ------------------------------------------------------------

        test "a stale full-match row job applies nothing and leaves progress alone" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "new-run")
          @adapter.expects(:finder).never
          Core::MatchProgress.expects(:call).never

          ::Lists::Wizard::MatchRowJob.new.perform(item.id, false, 1, "old-run")

          assert_equal "pending", Core::RowState.new(item.reload).bucket
          assert_equal "running", @list.reload.wizard_manager.step_status("match")
        end

        test "a row job superseded while the finder ran applies nothing" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "run-1")
          manager = @list.wizard_manager
          finder = ListWizardHelper::FakeFinder.new(->(subject) {
            manager.write_step!(step: "match", status: "running", metadata: {"run_id" => "run-2"})
            wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])
          })
          @adapter.stubs(:finder).returns(finder)
          Core::MatchProgress.expects(:call).never

          ::Lists::Wizard::MatchRowJob.new.perform(item.id, false, 1, "run-1")

          assert_equal "pending", Core::RowState.new(item.reload).bucket
        end

        test "StartMatch matches its rows under its run id and a stale one matches nothing" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "run-1")
          finder = ListWizardHelper::FakeFinder.new(->(subject) {
            wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule)
          })
          @adapter.stubs(:finder).returns(finder)

          assert_nil Core::StartMatch.call(list: @list, run_id: "stale")
          assert_empty finder.calls

          Core::StartMatch.call(list: @list, run_id: "run-1")
          assert_equal [item.id], finder.calls.map { |call| call[:subject].id }
          assert_equal "completed", @list.reload.wizard_manager.step_status("match")
        end

        test "a source retry carries the run id" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "run-1")
          @adapter.stubs(:finder).returns(ListWizardHelper::FakeFinder.new(->(subject) {
            wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, sources_failed: [:open_library])
          }))

          Sidekiq::Testing.fake! do
            ::Lists::Wizard::MatchRowJob.jobs.clear
            ::Lists::Wizard::MatchRowJob.new.perform(item.id, false, 1, "run-1")
            assert_equal [[item.id, false, 2, "run-1"]], ::Lists::Wizard::MatchRowJob.jobs.map { |job| job["args"] }
          end
        end

        test "a single-row re-match needs no run id" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "run-1", status: "completed")
          @adapter.stubs(:finder).returns(ListWizardHelper::FakeFinder.new(->(subject) {
            wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])
          }))

          ::Lists::Wizard::MatchRowJob.new.perform(item.id, true, 1, nil)

          assert_not_equal "pending", Core::RowState.new(item.reload).bucket
        end

        test "retries exhausted for a stale run flags nothing; for the current run it does" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "new-run")
          block = ::Lists::Wizard::MatchRowJob.sidekiq_retries_exhausted_block

          block.call({"args" => [item.id, false, 3, "old-run"]}, StandardError.new("boom"))
          assert_equal "pending", Core::RowState.new(item.reload).bucket

          block.call({"args" => [item.id, false, 3, "new-run"]}, StandardError.new("boom"))
          assert_equal "flagged", Core::RowState.new(item.reload).bucket
        end

        test "a stale exhaustion cannot flag a row the newer run re-marked pending, even if an unlocked check passed" do
          item = wizard_row(@list, position: 1, title: "Emma")
          start("match", "new-run")
          # An unlocked check made just before the newer run started would have passed.
          ::Services::Lists::Wizard::StateManager.any_instance.stubs(:run_current?).returns(true)

          ::Lists::Wizard::MatchRowJob.sidekiq_retries_exhausted_block.call({"args" => [item.id, false, 3, "old-run"]}, StandardError.new("boom"))

          assert_equal "pending", Core::RowState.new(item.reload).bucket
        end

        test "progress from a stale run does not complete the step" do
          start("match", "new-run")

          Core::MatchProgress.call(list: @list, run_id: "old-run")

          assert_equal "running", @list.reload.wizard_manager.step_status("match")
        end

        # ---- Import -----------------------------------------------------------

        test "a stale ImportJob is refused even after the newer run completed" do
          row = create_row(1, "War and Peace")
          start("import", "new-run", status: "completed")
          @adapter.expects(:create).never

          assert_nil Core::ImportRows.call(list: @list, adapter: @adapter, run_id: "old-run")

          assert_nil row.reload.listable_id
          assert_equal ["completed", "new-run"], [@list.reload.wizard_manager.step_status("import"), @list.wizard_manager.step_metadata("import")["run_id"]]
        end

        test "a superseded import stops before the next row" do
          first = create_row(1, "War and Peace")
          second = create_row(2, "A Game of Thrones")
          start("import", "run-1")
          manager = @list.wizard_manager
          created = []
          @adapter.stubs(:recheck).returns(nil)
          book = books_books(:war_and_peace)
          @adapter.define_singleton_method(:create) do |item, **|
            created << item.id
            manager.write_step!(step: "import", status: "running", metadata: {"run_id" => "run-2"})
            book
          end

          Core::ImportRows.call(list: ::List.find(@list.id), adapter: @adapter, run_id: "run-1")

          assert_equal [first.id], created
          assert_nil second.reload.listable_id
          assert_equal ["running", "run-2"], [@list.reload.wizard_manager.step_status("import"), @list.wizard_manager.step_metadata("import")["run_id"]]
        end

        # ---- Restart ----------------------------------------------------------

        test "a restart makes every older job a no-op" do
          wizard_row(@list, position: 1, title: "Emma")
          create_row(2, "War and Peace")
          %w[parse match import].each { |step| start(step, "old-run") }
          @list.wizard_manager.reset!
          before = @list.list_items.reload.map { |item| [item.id, item.metadata, item.listable_id] }
          @adapter.expects(:parse).never
          @adapter.expects(:finder).never
          @adapter.expects(:create).never

          ::Lists::Wizard::ParseJob.new.perform(@list.id, "old-run")
          ::Lists::Wizard::MatchJob.new.perform(@list.id, "old-run")
          ::Lists::Wizard::MatchRowJob.new.perform(@list.list_items.first.id, false, 1, "old-run")
          ::Lists::Wizard::ImportJob.new.perform(@list.id, "old-run")

          assert_equal before, @list.list_items.reload.map { |item| [item.id, item.metadata, item.listable_id] }
          assert_equal({}, @list.reload.wizard_state["steps"])
        end

        # ---- Sidekiq options --------------------------------------------------

        test "the step jobs do not retry; a failure is a failed step the admin re-runs" do
          assert_equal [false, false, false], [::Lists::Wizard::ParseJob, ::Lists::Wizard::MatchJob, ::Lists::Wizard::ImportJob]
            .map { |job| job.get_sidekiq_options["retry"] }
        end
      end
    end
  end
end
