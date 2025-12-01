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

  test "should advance to next step for non-job steps" do
    @list.update!(wizard_state: {"current_step" => 4, "import_source" => "custom_html", "job_status" => "idle"})

    post advance_step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    @list.reload
    assert_equal 5, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "import")
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

  test "source step shows import source choice" do
    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "source")

    assert_response :success
    assert_select "input[type='radio'][name='import_source']", count: 2
  end

  test "advancing from source with custom_html goes to parse step" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "source",
      import_source: "custom_html"
    )

    @list.reload
    assert_equal 1, @list.wizard_current_step
    assert_equal "custom_html", @list.wizard_state["import_source"]
    assert_redirected_to step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )
  end

  test "advancing from source with musicbrainz_series goes to import step" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "source",
      import_source: "musicbrainz_series"
    )

    @list.reload
    assert_equal 5, @list.wizard_current_step
    assert_equal "musicbrainz_series", @list.wizard_state["import_source"]
    assert_redirected_to step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "import"
    )
  end

  test "advancing from source without selection shows error" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "source"
    )

    @list.reload
    assert_equal 0, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/source}, response.location
    assert_equal "Please select an import source", flash[:alert]
  end

  test "advancing from source with invalid selection shows error" do
    @list.update!(wizard_state: {"current_step" => 0})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "source",
      import_source: "invalid_option"
    )

    @list.reload
    assert_equal 0, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/source}, response.location
    assert_equal "Please select an import source", flash[:alert]
  end

  test "parse step loads HTML preview" do
    @list.update!(raw_html: "Test HTML content")
    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")

    assert_response :success
    assert_match "Test HTML", response.body
  end

  test "advancing from parse step enqueues job when idle" do
    @list.update!(wizard_state: {"current_step" => 1, "job_status" => "idle"})

    Music::Songs::WizardParseListJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )

    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/parse}, response.location
    assert_match(/notice=Parsing\+started/, response.location)
  end

  test "advancing from parse step proceeds when job completed" do
    @list.update!(wizard_state: {"current_step" => 1, "job_status" => "completed"})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )

    @list.reload
    assert_equal 2, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "enrich")
  end

  test "advancing from parse step blocks when job running" do
    @list.update!(wizard_state: {"current_step" => 1, "job_status" => "running"})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )

    @list.reload
    assert_equal 1, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/parse}, response.location
    assert_match(/alert=Parsing\+in\+progress/, response.location)
  end

  test "enrich step loads item counts" do
    @list.list_items.unverified.destroy_all
    3.times do |i|
      @list.list_items.create!(
        listable_type: "Music::Song",
        verified: false,
        position: i + 1,
        metadata: {"title" => "Song #{i + 1}", "artists" => ["Artist"]}
      )
    end

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "enrich")

    assert_response :success
  end

  test "advancing from enrich step enqueues job when idle" do
    @list.update!(wizard_state: {"current_step" => 2, "job_status" => "idle"})
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Test Song", "artists" => ["Artist"]}
    )

    Music::Songs::WizardEnrichListItemsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich"
    )

    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/enrich}, response.location
    assert_match(/notice=Enrichment\+started/, response.location)
  end

  test "advancing from enrich step proceeds when job completed" do
    @list.update!(wizard_state: {"current_step" => 2, "job_status" => "completed"})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich"
    )

    @list.reload
    assert_equal 3, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "validate")
  end

  test "advancing from enrich step blocks when job running" do
    @list.update!(wizard_state: {"current_step" => 2, "job_status" => "running"})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich"
    )

    @list.reload
    assert_equal 2, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/enrich}, response.location
    assert_match(/alert=Enrichment\+in\+progress/, response.location)
  end

  test "re-enriching from completed state starts new job" do
    @list.update!(wizard_state: {"current_step" => 2, "job_status" => "completed"})

    Music::Songs::WizardEnrichListItemsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich",
      reenrich: "true"
    )

    @list.reload
    assert_equal "running", @list.wizard_job_status
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/enrich}, response.location
    assert_match(/notice=Re-enrichment\+started/, response.location)
  end

  test "advancing from enrich step resets job status for next step" do
    @list.update!(wizard_state: {
      "current_step" => 2,
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {"opensearch_matches" => 5}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich"
    )

    @list.reload
    assert_equal "idle", @list.wizard_job_status
    assert_equal 0, @list.wizard_job_progress
  end
end
