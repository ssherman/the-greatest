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
    # Use step-namespaced structure
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

    get step_status_admin_songs_list_wizard_path(list_id: @list.id, step: "parse", format: :json)

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "running", json_response["status"]
    assert_equal 50, json_response["progress"]
    assert_nil json_response["error"]
    assert_equal({"total_items" => 100}, json_response["metadata"])
  end

  test "should advance to next step for non-job steps" do
    @list.list_items.destroy_all
    @song = music_songs(:time)
    @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {"title" => "Valid Song", "artists" => ["Artist"]}
    )
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
    assert_match(/alert=Please\+select\+an\+import\+source/, response.location)
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
    assert_match(/alert=Please\+select\+an\+import\+source/, response.location)
  end

  test "parse step loads HTML preview" do
    @list.update!(raw_html: "Test HTML content")
    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")

    assert_response :success
    assert_match "Test HTML", response.body
  end

  test "advancing from parse step enqueues job when idle" do
    # Use step-namespaced structure - parse status is idle
    @list.update!(wizard_state: {
      "current_step" => 1,
      "steps" => {"parse" => {"status" => "idle", "progress" => 0}}
    })

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
    # Use step-namespaced structure - parse status is completed
    @list.update!(wizard_state: {
      "current_step" => 1,
      "steps" => {"parse" => {"status" => "completed", "progress" => 100}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )

    @list.reload
    assert_equal 2, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "enrich")
  end

  test "advancing from parse step blocks when job running" do
    # Use step-namespaced structure - parse status is running
    @list.update!(wizard_state: {
      "current_step" => 1,
      "steps" => {"parse" => {"status" => "running", "progress" => 50}}
    })

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
    # Use step-namespaced structure - enrich status is idle
    @list.update!(wizard_state: {
      "current_step" => 2,
      "steps" => {"enrich" => {"status" => "idle", "progress" => 0}}
    })
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
    # Use step-namespaced structure - enrich status is completed
    @list.update!(wizard_state: {
      "current_step" => 2,
      "steps" => {"enrich" => {"status" => "completed", "progress" => 100}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich"
    )

    @list.reload
    assert_equal 3, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "validate")
  end

  test "advancing from enrich step blocks when job running" do
    # Use step-namespaced structure - enrich status is running
    @list.update!(wizard_state: {
      "current_step" => 2,
      "steps" => {"enrich" => {"status" => "running", "progress" => 50}}
    })

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
    # Use step-namespaced structure - enrich status is completed
    @list.update!(wizard_state: {
      "current_step" => 2,
      "steps" => {"enrich" => {"status" => "completed", "progress" => 100}}
    })

    Music::Songs::WizardEnrichListItemsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich",
      reenrich: "true"
    )

    @list.reload
    assert_equal "running", @list.wizard_step_status("enrich")
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/enrich}, response.location
    assert_match(/notice=Re-enrichment\+started/, response.location)
  end

  test "advancing from enrich step preserves enrich status for back navigation" do
    # With step-namespaced status, advancing should NOT reset the step status
    @list.update!(wizard_state: {
      "current_step" => 2,
      "steps" => {
        "enrich" => {
          "status" => "completed",
          "progress" => 100,
          "error" => nil,
          "metadata" => {"opensearch_matches" => 5}
        }
      }
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "enrich"
    )

    @list.reload
    # Enrich status should remain completed (not reset to idle)
    assert_equal "completed", @list.wizard_step_status("enrich")
    assert_equal 100, @list.wizard_step_progress("enrich")
    # New step (validate) should be idle
    assert_equal "idle", @list.wizard_step_status("validate")
  end

  # Validate step tests
  test "validate step loads item counts" do
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Song 1", "artists" => ["Artist"], "song_id" => 123, "opensearch_match" => true}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {"title" => "Song 2", "artists" => ["Artist"], "mb_recording_id" => "abc", "musicbrainz_match" => true}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "Song 3", "artists" => ["Artist"]}
    )

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "validate")

    assert_response :success
  end

  test "advancing from validate step enqueues job when idle" do
    @list.update!(wizard_state: {
      "current_step" => 3,
      "steps" => {"validate" => {"status" => "idle", "progress" => 0}}
    })
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Song", "artists" => ["Artist"], "mb_recording_id" => "abc"}
    )

    Music::Songs::WizardValidateListItemsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "validate"
    )

    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/validate}, response.location
    assert_match(/notice=Validation\+started/, response.location)
  end

  test "advancing from validate step proceeds when job completed" do
    @list.update!(wizard_state: {
      "current_step" => 3,
      "steps" => {"validate" => {"status" => "completed", "progress" => 100}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "validate"
    )

    @list.reload
    assert_equal 4, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")
  end

  test "advancing from validate step blocks when job running" do
    @list.update!(wizard_state: {
      "current_step" => 3,
      "steps" => {"validate" => {"status" => "running", "progress" => 50}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "validate"
    )

    @list.reload
    assert_equal 3, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/validate}, response.location
    assert_match(/alert=Validation\+in\+progress/, response.location)
  end

  test "revalidate param triggers re-validation" do
    @list.update!(wizard_state: {
      "current_step" => 3,
      "steps" => {"validate" => {"status" => "completed", "progress" => 100}}
    })
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Song", "artists" => ["Artist"], "mb_recording_id" => "abc"}
    )

    Music::Songs::WizardValidateListItemsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "validate",
      revalidate: "true"
    )

    @list.reload
    assert_equal "running", @list.wizard_step_status("validate")
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/validate}, response.location
    assert_match(/notice=Re-validation\+started/, response.location)
  end

  # Review step tests
  test "review step loads all items with associations" do
    @list.list_items.unverified.destroy_all
    @song = music_songs(:time)

    @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {"title" => "Come Together", "artists" => ["The Beatles"], "opensearch_match" => true}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {"title" => "Imagine", "artists" => ["John Lennon"], "ai_match_invalid" => true}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "Missing Song", "artists" => ["Unknown"]}
    )

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    assert_response :success
  end

  test "review step calculates correct counts" do
    @list.list_items.unverified.destroy_all
    @song = music_songs(:time)

    @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {"title" => "Valid", "artists" => ["Artist"]}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {"title" => "Invalid", "artists" => ["Artist"], "ai_match_invalid" => true}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "Missing", "artists" => ["Artist"]}
    )

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    assert_response :success
  end

  test "can advance from review to import step with valid items" do
    @list.list_items.unverified.destroy_all
    @song = music_songs(:time)

    @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {"title" => "Valid Song", "artists" => ["Artist"]}
    )

    @list.update!(wizard_state: {"current_step" => 4})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "review"
    )

    @list.reload
    assert_equal 5, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "import")
  end

  test "cannot advance from review step without valid items" do
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Invalid Song", "artists" => ["Artist"], "ai_match_invalid" => true}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {"title" => "Missing Song", "artists" => ["Artist"]}
    )

    @list.update!(wizard_state: {"current_step" => 4})

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "review"
    )

    @list.reload
    assert_equal 4, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/review}, response.location
    assert_match(/alert=No\+valid\+items\+to\+import/, response.location)
  end

  test "can go back from review to validate step" do
    @list.update!(wizard_state: {"current_step" => 4})

    post back_step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    @list.reload
    assert_equal 3, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "validate")
  end

  # Import step tests
  test "import step loads item categories correctly" do
    @list.list_items.destroy_all

    @song = music_songs(:time)
    @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {"title" => "Linked Song", "artists" => ["Artist"]}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {"title" => "To Import", "artists" => ["Artist"], "mb_recording_id" => "abc123"}
    )
    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "No Match", "artists" => ["Artist"]}
    )

    @list.update!(wizard_state: {"current_step" => 5, "import_source" => "custom_html"})

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "import")

    assert_response :success
  end

  test "advancing from import step enqueues job when idle" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "import_source" => "custom_html",
      "steps" => {"import" => {"status" => "idle", "progress" => 0}}
    })

    Music::Songs::WizardImportSongsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "import"
    )

    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/import}, response.location
    assert_match(/notice=Import\+started/, response.location)
  end

  test "advancing from import step proceeds when job completed" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "import_source" => "custom_html",
      "steps" => {"import" => {"status" => "completed", "progress" => 100}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "import"
    )

    @list.reload
    assert_equal 6, @list.wizard_current_step
    assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "complete")
  end

  test "advancing from import step blocks when job running" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "import_source" => "custom_html",
      "steps" => {"import" => {"status" => "running", "progress" => 50}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "import"
    )

    @list.reload
    assert_equal 5, @list.wizard_current_step
    assert_response :redirect
    assert_match %r{/admin/songs/lists/#{@list.id}/wizard/step/import}, response.location
    assert_match(/alert=Import\+in\+progress/, response.location)
  end

  test "import step handles zero items to import" do
    @list.list_items.destroy_all
    @list.update!(wizard_state: {"current_step" => 5, "import_source" => "custom_html"})

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "import")

    assert_response :success
  end

  test "advancing from import step enqueues job when failed" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "import_source" => "custom_html",
      "steps" => {"import" => {"status" => "failed", "progress" => 0, "error" => "Previous error"}}
    })

    Music::Songs::WizardImportSongsJob.expects(:perform_async).with(@list.id).once

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "import"
    )

    @list.reload
    assert_equal "running", @list.wizard_step_status("import")
    assert_response :redirect
    assert_match(/notice=Import\+started/, response.location)
  end

  test "import step sets completed_at when advancing to complete step" do
    @list.update!(wizard_state: {
      "current_step" => 5,
      "import_source" => "custom_html",
      "steps" => {"import" => {"status" => "completed", "progress" => 100}}
    })

    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "import"
    )

    @list.reload
    assert_not_nil @list.wizard_state["completed_at"]
  end

  test "review step displays item counts correctly" do
    @list.list_items.destroy_all

    # Create verified items (valid) - each with a unique song
    songs = []
    3.times do |i|
      songs << Music::Song.create!(title: "Valid Song #{i + 1}")
    end
    songs.each_with_index do |song, i|
      @list.list_items.create!(
        listable: song,
        listable_type: "Music::Song",
        verified: true,
        position: i + 1,
        metadata: {"title" => song.title, "artists" => ["Artist"]}
      )
    end

    # Create invalid items (ai_match_invalid) - no listable
    2.times do |i|
      @list.list_items.create!(
        listable_type: "Music::Song",
        listable_id: nil,
        verified: false,
        position: 10 + i,
        metadata: {"title" => "Invalid Song #{i + 1}", "artists" => ["Artist"], "ai_match_invalid" => true}
      )
    end

    # Create missing items (unverified, no ai_match_invalid) - no listable
    @list.list_items.create!(
      listable_type: "Music::Song",
      listable_id: nil,
      verified: false,
      position: 20,
      metadata: {"title" => "Missing Song", "artists" => ["Artist"]}
    )

    @list.update!(wizard_state: {"current_step" => 4, "import_source" => "custom_html"})

    get step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    assert_response :success
    # Verify the stats are displayed correctly (Total: 6, Valid: 3, Invalid: 2, Missing: 1)
    assert_select ".stat-value", text: "6"  # Total Items
    assert_select ".stat-value", text: "3"  # Valid count
    assert_select ".stat-value", text: "2"  # Invalid count
    assert_select ".stat-value", text: "1"  # Missing count
  end
end
