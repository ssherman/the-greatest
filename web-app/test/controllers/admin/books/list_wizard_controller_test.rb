# frozen_string_literal: true

require "test_helper"

class Admin::Books::ListWizardControllerTest < ActionDispatch::IntegrationTest
  include ListWizardHelper

  RowState = ::Services::Lists::Wizard::Core::RowState

  setup do
    host! Rails.application.config.domains[:books]
    @admin = users(:admin_user)
    @user = users(:regular_user)
    @list = wizard_list
  end

  def sign_in_with(level)
    @user.domain_roles.create!(domain: :books, permission_level: level)
    sign_in_as(@user, stub_auth: true)
  end

  def wizard(name = nil, **params) = send([name, "admin_books_list_wizard_path"].compact.join("_"), list_id: @list.id, **params)

  def step(name, **params) = wizard(:step, step: name, **params)

  # ---- navigation ------------------------------------------------------------

  test "a list with no wizard state opens on Paste" do
    sign_in_as(@admin, stub_auth: true)
    @list.update_columns(wizard_state: nil)

    get wizard

    assert_redirected_to step("paste")
  end

  test "every step renders" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["not_found"]})

    %w[paste parse match review import done].each do |name|
      get step(name)
      assert_response :success, name
    end
    get wizard(:step, step: "review", filter: "bogus")
    assert_response :success
    get wizard(:step, step: "review", filter: "all", page: "2")
    assert_response :success
  end

  test "step status answers JSON" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "match", status: "running", progress: 25)

    get wizard(:step_status, step: "match"), as: :json

    assert_equal ["running", 25], JSON.parse(response.body).values_at("status", "progress")
  end

  test "saving content starts the parse and moves to Parse; blank content is refused" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.expects(:perform_async).with(@list.id).once

    post wizard(:save_content), params: {raw_content: "1. Emma by Jane Austen"}

    assert_redirected_to step("parse")
    @list.reload
    assert_equal ["1. Emma by Jane Austen", "parse", "running"], [@list.raw_content, @list.wizard_manager.current_step_name, @list.wizard_manager.step_status("parse")]

    assert_equal false, @list.wizard_state["batch_mode"]

    post wizard(:save_content), params: {raw_content: " "}
    assert_redirected_to step("paste")
  end

  test "saving content with the large-list box ticked turns batch mode on" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.stubs(:perform_async)

    post wizard(:save_content), params: {raw_content: "1. Emma by Jane Austen", batch_mode: "1"}

    assert_equal true, @list.reload.wizard_state["batch_mode"]
  end

  test "Next from Paste parses the saved content; with none saved it is refused" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.expects(:perform_async).with(@list.id).once

    post wizard(:advance_step, step: "paste")
    assert_redirected_to step("parse")

    @list.update_columns(raw_content: "")
    ::Lists::Wizard::ParseJob.expects(:perform_async).never
    post wizard(:advance_step, step: "paste")
    assert_redirected_to step("paste")
  end

  test "Next from a running step waits" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "parse", status: "running")
    ::Lists::Wizard::MatchJob.expects(:perform_async).never

    post wizard(:advance_step, step: "parse")

    assert_redirected_to step("parse")
    assert_equal "paste", @list.reload.wizard_manager.current_step_name
  end

  test "Next from a completed Parse starts Match" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "parse", status: "completed")
    ::Lists::Wizard::MatchJob.expects(:perform_async).with(@list.id).once

    post wizard(:advance_step, step: "parse")

    assert_redirected_to step("match")
    assert_equal ["match", "running"], [@list.reload.wizard_manager.current_step_name, @list.wizard_manager.step_status("match")]
  end

  test "Next from a completed Match goes to Review; from Import to Done, completing the wizard" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "match", status: "completed")
    @list.wizard_manager.write_step!(step: "import", status: "completed")

    post wizard(:advance_step, step: "match")
    assert_redirected_to step("review")

    post wizard(:advance_step, step: "import")
    assert_redirected_to step("done")
    assert @list.reload.wizard_state["completed_at"].present?
  end

  test "finishing Review with flagged rows is refused without the confirmation" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    ::Lists::Wizard::ImportJob.expects(:perform_async).never

    post wizard(:advance_step, step: "review")

    assert_redirected_to step("review")
    assert flash[:alert].present?
  end

  test "finishing Review with flagged rows and the confirmation starts Import" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    ::Lists::Wizard::ImportJob.expects(:perform_async).with(@list.id, instance_of(String)).once

    post wizard(:advance_step, step: "review"), params: {confirm_unlinked: "1"}

    assert_redirected_to step("import")
    assert @list.reload.wizard_manager.step_metadata("import")["run_id"].present?
  end

  test "finishing Review with nothing flagged needs no confirmation" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched"})
    ::Lists::Wizard::ImportJob.expects(:perform_async).with(@list.id, instance_of(String)).once

    post wizard(:advance_step, step: "review")

    assert_redirected_to step("import")
  end

  test "an idle Import step's Start goes through the unlinked-rows confirmation" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    ::Lists::Wizard::ImportJob.expects(:perform_async).never

    post wizard(:advance_step, step: "import")

    assert_redirected_to step("review")
    assert flash[:alert].present?
    assert_equal "idle", @list.reload.wizard_manager.step_status("import")
  end

  test "an idle Import step's Start with nothing flagged starts the import" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched"})
    ::Lists::Wizard::ImportJob.expects(:perform_async).with(@list.id, instance_of(String)).once

    post wizard(:advance_step, step: "import")

    assert_redirected_to step("import")
  end

  test "retrying a failed Import needs no second confirmation" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    @list.wizard_manager.write_step!(step: "import", status: "failed", error: "boom")
    ::Lists::Wizard::ImportJob.expects(:perform_async).with(@list.id, instance_of(String)).once

    post wizard(:advance_step, step: "import")

    assert_redirected_to step("import")
    assert_equal "running", @list.reload.wizard_manager.step_status("import")
  end

  test "Back keeps the steps' state" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
    @list.wizard_manager.go_to_step!(3)

    post wizard(:back_step, step: "review")

    assert_redirected_to step("match")
    assert_equal ["match", "completed"], [@list.reload.wizard_manager.current_step_name, @list.wizard_manager.step_status("match")]
  end

  test "re-parse and re-match start their jobs" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.expects(:perform_async).with(@list.id)
    ::Lists::Wizard::MatchJob.expects(:perform_async).with(@list.id)

    post wizard(:reparse)
    assert_redirected_to step("parse")
    @list.wizard_manager.write_step!(step: "parse", status: "completed") # the stubbed parse job "finished"
    post wizard(:rematch)
    assert_redirected_to step("match")
  end

  test "nothing that starts a job, deletes rows or changes a row runs while a job is running" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"], wizard: {bucket: "flagged", reasons: ["unsure"]})
    @list.wizard_manager.write_step!(step: "parse", status: "completed")
    @list.wizard_manager.write_step!(step: "match", status: "running")
    [::Lists::Wizard::ParseJob, ::Lists::Wizard::MatchJob, ::Lists::Wizard::ImportJob, ::Lists::Wizard::MatchRowJob].each do |job|
      job.expects(:perform_async).never
    end

    post wizard(:save_content), params: {raw_content: "1. Persuasion by Jane Austen"}
    assert_redirected_to step("match")
    post wizard(:reparse)
    assert_redirected_to step("match")
    post wizard(:rematch)
    assert_redirected_to step("match")
    post wizard(:advance_step, step: "parse")
    assert_redirected_to step("match")
    post wizard(:advance_step, step: "paste")
    assert_redirected_to step("match")
    post wizard(:advance_step, step: "review"), params: {confirm_unlinked: "1"}
    assert_redirected_to step("match")
    post wizard(:advance_step, step: "import")
    assert_redirected_to step("match")
    post wizard(:restart)
    assert_redirected_to step("match")

    post wizard(:link_row, row_id: row.id), params: {record_id: books_books(:got).id}
    assert_redirected_to step("match")
    post wizard(:create_row, row_id: row.id), params: {external_key: "OL9W"}
    assert_redirected_to step("match")
    post wizard(:create_row_from_text, row_id: row.id)
    assert_redirected_to step("match")
    post wizard(:edit_row, row_id: row.id), params: {title: "Persuasion", subtitle: "", authors: "Jane Austen", year: "1817"}
    assert_redirected_to step("match")
    post wizard(:remove_row, row_id: row.id)
    assert_redirected_to step("match")

    row.reload
    assert_equal ["Emma", "flagged", nil], [row.metadata["title"], RowState.new(row).bucket, row.listable_id]
    assert_not_equal "1. Persuasion by Jane Austen", @list.reload.raw_content
  end

  # ---- a step that stopped ---------------------------------------------------

  test "a running step that has not been written for 31 minutes no longer blocks a re-run" do
    sign_in_as(@admin, stub_auth: true)
    travel_to 31.minutes.ago do
      @list.wizard_manager.write_step!(step: "match", status: "running")
    end
    @list.wizard_manager.write_step!(step: "parse", status: "completed")
    ::Lists::Wizard::MatchJob.expects(:perform_async).with(@list.id).once

    get step("match")
    assert_response :success
    post wizard(:rematch)
    assert_redirected_to step("match")
    assert_not @list.reload.wizard_manager.step_stalled?("match")
  end

  test "Start on a stalled step runs it again" do
    sign_in_as(@admin, stub_auth: true)
    travel_to 31.minutes.ago do
      @list.wizard_manager.write_step!(step: "match", status: "running")
    end
    ::Lists::Wizard::MatchJob.expects(:perform_async).with(@list.id).once

    post wizard(:advance_step, step: "match")

    assert_redirected_to step("match")
    assert_not @list.reload.wizard_manager.step_stalled?("match")
  end

  test "a stalled step allows re-parse" do
    sign_in_as(@admin, stub_auth: true)
    travel_to 31.minutes.ago do
      @list.wizard_manager.write_step!(step: "parse", status: "running")
    end
    ::Lists::Wizard::ParseJob.expects(:perform_async).with(@list.id).once

    post wizard(:reparse)
    assert_redirected_to step("parse")
  end

  test "a stalled step allows restart" do
    sign_in_as(@admin, stub_auth: true)
    unsettled = wizard_row(@list, position: 1, title: "Unsettled", wizard: {bucket: "matched"})
    travel_to 31.minutes.ago do
      @list.wizard_manager.write_step!(step: "match", status: "running")
    end

    post wizard(:restart)

    assert_redirected_to wizard
    assert_not ::ListItem.exists?(unsettled.id)
  end

  test "a Match advanced by the row jobs' progress writes still blocks restart and re-parse" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched"})
    wizard_row(@list, position: 2, title: "Persuasion")
    @list.wizard_manager.write_step!(step: "match", status: "running")
    ::Services::Lists::Wizard::Core::MatchProgress.call(list: @list)
    ::Lists::Wizard::ParseJob.expects(:perform_async).never

    assert_not @list.reload.wizard_manager.step_stalled?("match")
    post wizard(:restart)
    assert_redirected_to step("match")
    post wizard(:reparse)
    assert_redirected_to step("match")
    assert ::ListItem.exists?(row.id)
  end

  test "finishing Review is refused while a row is still pending" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched"})
    wizard_row(@list, position: 2, title: "Persuasion")
    ::Lists::Wizard::ImportJob.expects(:perform_async).never

    post wizard(:advance_step, step: "review"), params: {confirm_unlinked: "1"}

    assert_redirected_to step("review")
    assert flash[:alert].present?
    assert_equal "idle", @list.reload.wizard_manager.step_status("import")
  end

  test "a failing restart leaves the rows and the wizard state both untouched" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Unsettled", wizard: {bucket: "matched"})
    @list.wizard_manager.go_to_step!(3)
    ::Services::Lists::Wizard::Books::StateManager.any_instance.stubs(:reset!).raises(ActiveRecord::StatementInvalid, "boom")

    assert_raises(ActiveRecord::StatementInvalid) { post wizard(:restart) }

    assert ::ListItem.exists?(row.id)
    assert_equal "review", @list.reload.wizard_manager.current_step_name
  end

  test "a step written 29 minutes ago still blocks" do
    sign_in_as(@admin, stub_auth: true)
    travel_to 29.minutes.ago do
      @list.wizard_manager.write_step!(step: "parse", status: "running")
    end
    ::Lists::Wizard::ParseJob.expects(:perform_async).never

    post wizard(:reparse)

    assert_redirected_to step("parse")
  end

  # ---- restart ---------------------------------------------------------------

  test "restart deletes only unsettled rows and returns to Paste" do
    sign_in_as(@admin, stub_auth: true)
    unsettled = wizard_row(@list, position: 1, title: "Unsettled", wizard: {bucket: "matched"})
    settled = wizard_row(@list, position: 2, title: "Settled", wizard: {bucket: "matched", settled: true})
    @list.wizard_manager.go_to_step!(3)

    post wizard(:restart)

    assert_redirected_to wizard
    assert_not ::ListItem.exists?(unsettled.id)
    assert ::ListItem.exists?(settled.id)
    assert_equal "paste", @list.reload.wizard_manager.current_step_name
  end

  test "restart keeps rows from before the wizard" do
    sign_in_as(@admin, stub_auth: true)
    old = @list.list_items.create!(listable: books_books(:got), position: 1)

    post wizard(:restart)

    assert ::ListItem.exists?(old.id)
  end

  # ---- row actions -----------------------------------------------------------

  test "linking a candidate links and settles the row" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "A Game of Thrones", wizard: {bucket: "flagged", reasons: ["unsure"]})

    post wizard(:link_row, row_id: row.id), params: {record_id: books_books(:got).id, filter: "all"}

    assert_redirected_to wizard(:step, step: "review", filter: "all")
    assert_equal [books_books(:got).id, true], [row.reload.listable_id, RowState.new(row).settled?]
  end

  test "a row action sends the admin back to the page and filter they were on" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})

    post wizard(:remove_row, row_id: row.id, page: "3"), params: {filter: "all"}

    assert_redirected_to wizard(:step, step: "review", filter: "all", page: 3)
  end

  test "a row action with no page leaves the page out" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})

    post wizard(:remove_row, row_id: row.id, page: "junk"), params: {filter: "create"}

    assert_redirected_to wizard(:step, step: "review", filter: "create")
  end

  test "linking a book another row holds is refused with a message, not an error" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "A Game of Thrones", listable: books_books(:got), wizard: {bucket: "matched"})
    row = wizard_row(@list, position: 2, title: "Game of Thrones", wizard: {bucket: "flagged", reasons: ["unsure"]})

    post wizard(:link_row, row_id: row.id), params: {record_id: books_books(:got).id}

    assert_redirected_to step("review")
    assert flash[:alert].present?
    assert_nil row.reload.listable_id
  end

  test "create from a work, create from text, edit and remove each act on the row" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Dune", authors: ["Frank Herbert"], wizard: {bucket: "flagged", reasons: ["ai_only_pick"]})
    work = ol_candidate("OL9W")
    decision = wizard_match(subject: row, outcome: :unmatched, decided_by: :ai, external: work, candidates: [work]).decision
    RowState.new(row).merge("match_decision_id" => decision.id)
    row.save!

    post wizard(:create_row, row_id: row.id), params: {external_key: "OL9W"}
    assert_equal ["create", "OL9W"], [RowState.new(row.reload).bucket, RowState.new(row).ol_work_key]

    post wizard(:create_row_from_text, row_id: row.id)
    assert_equal ["create", nil], [RowState.new(row.reload).bucket, RowState.new(row).ol_work_key]

    ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(row.id, true)
    post wizard(:edit_row, row_id: row.id), params: {title: "Dune Messiah", subtitle: "", authors: "Frank Herbert", year: "1969"}
    assert_equal ["Dune Messiah", 1969], row.reload.metadata.values_at("title", "year")
    RowState.new(row).merge("bucket" => "flagged") # the stubbed re-match "finished"
    row.save!

    post wizard(:remove_row, row_id: row.id)
    assert_equal "removed", RowState.new(row.reload).bucket
  end

  test "a row on another list is not found" do
    sign_in_as(@admin, stub_auth: true)
    other = wizard_row(wizard_list(name: "Other"), position: 1, title: "Emma")

    post wizard(:remove_row, row_id: other.id)

    assert_response :not_found
  end

  # ---- auto-generated lists --------------------------------------------------

  test "an auto-generated list has no wizard" do
    sign_in_as(@admin, stub_auth: true)
    generated = ::Books::List.create!(name: "Generated", status: :unapproved, auto_generated_kind: :user_favorites)
    ::Lists::Wizard::ParseJob.expects(:perform_async).never

    get admin_books_list_wizard_path(list_id: generated.id)
    assert_redirected_to admin_books_list_path(generated)
    assert flash[:alert].present?

    post save_content_admin_books_list_wizard_path(list_id: generated.id), params: {raw_content: "1. Emma by Jane Austen"}
    assert_redirected_to admin_books_list_path(generated)
    assert_nil generated.reload.raw_content
  end

  # ---- permissions -----------------------------------------------------------

  test "a books viewer can look but not act" do
    sign_in_with(:viewer)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged"})

    get step("review")
    assert_response :success

    post wizard(:remove_row, row_id: row.id)
    assert_redirected_to books_root_path
    assert_equal "flagged", RowState.new(row.reload).bucket
  end

  test "a books editor can act but not restart" do
    sign_in_with(:editor)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged"})

    post wizard(:remove_row, row_id: row.id)
    assert_equal "removed", RowState.new(row.reload).bucket

    unsettled = wizard_row(@list, position: 2, title: "Persuasion")
    post wizard(:restart)
    assert_redirected_to books_root_path
    assert ::ListItem.exists?(unsettled.id)
  end

  test "a books moderator can restart" do
    sign_in_with(:moderator)
    unsettled = wizard_row(@list, position: 1, title: "Persuasion")

    post wizard(:restart)

    assert_not ::ListItem.exists?(unsettled.id)
  end
end
