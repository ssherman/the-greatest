# frozen_string_literal: true

require "test_helper"

class Admin::Games::ListWizardControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:games]
    @list = lists(:games_list)
    @admin_user = users(:admin_user)
    sign_in_as(@admin_user, stub_auth: true)
  end

  test "should redirect to current step on show" do
    @list.update!(wizard_state: {"current_step" => 2})

    get admin_games_list_wizard_path(list_id: @list.id)

    assert_redirected_to step_admin_games_list_wizard_path(list_id: @list.id, step: "enrich")
  end

  test "should show step view" do
    get step_admin_games_list_wizard_path(list_id: @list.id, step: "source")

    assert_response :success
    assert_select "h1", text: @list.name
  end

  test "should return status as JSON" do
    @list.update!(wizard_state: {
      "current_step" => 1,
      "steps" => {
        "parse" => {
          "status" => "running",
          "progress" => 50,
          "error" => nil,
          "metadata" => {"total_items" => 100}
        }
      }
    })

    get step_status_admin_games_list_wizard_path(list_id: @list.id, step: "parse", format: :json)

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "running", json_response["status"]
    assert_equal 50, json_response["progress"]
    assert_nil json_response["error"]
    assert_equal({"total_items" => 100}, json_response["metadata"])
  end

  test "should go back to previous step" do
    @list.update!(wizard_state: {"current_step" => 2})

    post back_step_admin_games_list_wizard_path(list_id: @list.id, step: "enrich")

    @list.reload
    assert_equal 1, @list.wizard_manager.current_step
    assert_redirected_to step_admin_games_list_wizard_path(list_id: @list.id, step: "parse")
  end

  test "should not go back before first step" do
    @list.update!(wizard_state: {"current_step" => 0})

    post back_step_admin_games_list_wizard_path(list_id: @list.id, step: "source")

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
  end

  test "should restart wizard and delete list items" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "completed_at" => Time.current.iso8601
    })
    # Ensure list has items to delete
    @list.list_items.destroy_all
    ListItem.create!(list: @list, listable_type: "Games::Game", position: 1, metadata: {"title" => "Test Game"})
    assert @list.list_items.count > 0

    post restart_admin_games_list_wizard_path(list_id: @list.id)

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_nil @list.wizard_state["completed_at"]
    assert_equal 0, @list.list_items.count
    assert_redirected_to admin_games_list_wizard_path(list_id: @list.id)
  end

  test "should restart wizard with no list items without error" do
    @list.list_items.destroy_all
    @list.update!(wizard_state: {"current_step" => 3})

    post restart_admin_games_list_wizard_path(list_id: @list.id)

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_redirected_to admin_games_list_wizard_path(list_id: @list.id)
  end

  test "should mark wizard as completed on last step advance" do
    @list.update!(wizard_state: {"current_step" => 6})

    post advance_step_admin_games_list_wizard_path(list_id: @list.id, step: "complete")

    @list.reload
    assert_equal 6, @list.wizard_manager.current_step
    assert_not_nil @list.wizard_state["completed_at"]
  end

  test "should reject invalid step name" do
    get step_admin_games_list_wizard_path(list_id: @list.id, step: "invalid_step")

    assert_response :redirect
    assert_match %r{/admin/lists/#{@list.id}/wizard}, response.location
  end

  test "source step shows only custom_html option" do
    get step_admin_games_list_wizard_path(list_id: @list.id, step: "source")

    assert_response :success
    assert_select "input[type='radio'][name='import_source']", count: 1
  end

  test "advancing from source with custom_html goes to parse step" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_games_list_wizard_path(
      list_id: @list.id,
      step: "source",
      import_source: "custom_html"
    )

    @list.reload
    assert_equal 1, @list.wizard_manager.current_step
    assert_equal "custom_html", @list.wizard_state["import_source"]
    assert_redirected_to step_admin_games_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )
  end

  test "advancing from source without selection shows error" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_games_list_wizard_path(
      list_id: @list.id,
      step: "source"
    )

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_response :redirect
  end

  test "advancing from source with invalid selection shows error" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_games_list_wizard_path(
      list_id: @list.id,
      step: "source",
      import_source: "musicbrainz_series"
    )

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_response :redirect
  end

  test "save_html saves raw html and redirects to parse" do
    post save_html_admin_games_list_wizard_path(list_id: @list.id), params: {
      raw_html: "<ol><li>Game 1</li></ol>"
    }

    @list.reload
    assert_equal "<ol><li>Game 1</li></ol>", @list.raw_html
    assert_response :redirect
    assert_match %r{/admin/lists/#{@list.id}/wizard/step/parse}, response.location
  end

  test "parse step shows html preview when html exists" do
    @list.update!(raw_html: "<ol><li>Game 1</li></ol>")

    get step_admin_games_list_wizard_path(list_id: @list.id, step: "parse")

    assert_response :success
  end

  test "advancing from parse when idle sets running status" do
    @list.update!(
      raw_html: "<ol><li>Game 1</li></ol>",
      wizard_state: {"current_step" => 1}
    )

    Games::WizardParseListJob.stubs(:perform_async)

    post advance_step_admin_games_list_wizard_path(list_id: @list.id, step: "parse")

    @list.reload
    assert_equal "running", @list.wizard_manager.step_status("parse")
    assert_response :redirect
  end

  test "advancing from enrich when idle sets running status" do
    @list.update!(wizard_state: {"current_step" => 2})

    Games::WizardEnrichListItemsJob.stubs(:perform_async)

    post advance_step_admin_games_list_wizard_path(list_id: @list.id, step: "enrich")

    @list.reload
    assert_equal "running", @list.wizard_manager.step_status("enrich")
    assert_response :redirect
  end

  test "advancing from validate when idle sets running status" do
    @list.update!(wizard_state: {"current_step" => 3})

    Games::WizardValidateListItemsJob.stubs(:perform_async)

    post advance_step_admin_games_list_wizard_path(list_id: @list.id, step: "validate")

    @list.reload
    assert_equal "running", @list.wizard_manager.step_status("validate")
    assert_response :redirect
  end

  test "review step renders without error" do
    @list.update!(wizard_state: {"current_step" => 4})

    get step_admin_games_list_wizard_path(list_id: @list.id, step: "review")

    assert_response :success
  end

  test "import step renders without error" do
    @list.update!(wizard_state: {"current_step" => 5})

    get step_admin_games_list_wizard_path(list_id: @list.id, step: "import")

    assert_response :success
  end

  test "complete step renders without error" do
    @list.update!(wizard_state: {"current_step" => 6})

    get step_admin_games_list_wizard_path(list_id: @list.id, step: "complete")

    assert_response :success
  end

  test "reparse destroys unverified items and resets step" do
    @list.list_items.destroy_all
    @list.update!(
      raw_html: "<ol><li>Game 1</li></ol>",
      wizard_state: {"current_step" => 1, "steps" => {"parse" => {"status" => "completed"}}}
    )
    ListItem.create!(list: @list, listable_type: "Games::Game", position: 1, metadata: {"title" => "Test"})

    assert_difference -> { @list.list_items.unverified.count }, -1 do
      post reparse_admin_games_list_wizard_path(list_id: @list.id)
    end

    assert_response :redirect
    assert_match %r{/admin/lists/#{@list.id}/wizard/step/parse}, response.location
  end

  test "state manager uses base class for games list" do
    manager = @list.wizard_manager
    assert_instance_of Services::Lists::Wizard::StateManager, manager
    assert_equal %w[source parse enrich validate review import complete], manager.steps
  end
end
