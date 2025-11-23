# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::ListWizardControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:music]
    @list = lists(:music_songs_list)
    @admin_user = users(:admin_user)
    sign_in_as(@admin_user, stub_auth: true)
  end

  test "should redirect to current step on show" do
    @list.update!(wizard_state: {"current_step" => 2})

    get admin_songs_list_wizard_path(list_id: @list.id)

    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "enrich")
  end

  test "should show step view" do
    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "source")

    assert_response :success
    assert_select "h1", text: @list.name
  end

  test "should return status as JSON" do
    @list.update!(wizard_state: {
      "job_status" => "running",
      "job_progress" => 50,
      "job_error" => nil,
      "job_metadata" => {"total_items" => 100}
    })

    get step_status_admin_songs_list_wizard_path(list_id: @list.id, step: "parse", format: :json)

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "running", json_response["status"]
    assert_equal 50, json_response["progress"]
    assert_nil json_response["error"]
    assert_equal({"total_items" => 100}, json_response["metadata"])
  end

  test "should advance to next step" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_songs_list_wizard_path(list_id: @list.id, step: "source")

    @list.reload
    assert_equal 1, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")
  end

  test "should go back to previous step" do
    @list.update!(wizard_state: {"current_step" => 2})

    post back_step_admin_songs_list_wizard_path(list_id: @list.id, step: "enrich")

    @list.reload
    assert_equal 1, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")
  end

  test "should not go back before first step" do
    @list.update!(wizard_state: {"current_step" => 0})

    post back_step_admin_songs_list_wizard_path(list_id: @list.id, step: "source")

    @list.reload
    assert_equal 0, @list.wizard_current_step
  end

  test "should restart wizard" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "completed_at" => Time.current.iso8601
    })

    post restart_admin_songs_list_wizard_path(list_id: @list.id)

    @list.reload
    assert_equal 0, @list.wizard_current_step
    assert_nil @list.wizard_state["completed_at"]
    assert_redirected_to admin_songs_list_wizard_path(list_id: @list.id)
  end

  test "should mark wizard as completed on last step advance" do
    @list.update!(wizard_state: {"current_step" => 6})

    post advance_step_admin_songs_list_wizard_path(list_id: @list.id, step: "complete")

    @list.reload
    assert_equal 6, @list.wizard_current_step
    assert_not_nil @list.wizard_state["completed_at"]
  end

  test "should reject invalid step name" do
    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "invalid_step")

    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard}, response.location
  end
end
