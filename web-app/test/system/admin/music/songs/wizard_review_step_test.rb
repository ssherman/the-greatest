# frozen_string_literal: true

require "application_system_test_case"

class WizardReviewStepTest < ApplicationSystemTestCase
  setup do
    Capybara.app_host = "http://#{Rails.application.config.domains[:music]}"
    @list = lists(:music_songs_list)
    @admin_user = users(:admin_user)
    @song = music_songs(:time)

    @list.list_items.unverified.destroy_all

    @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {
        "title" => "Valid Song",
        "artists" => ["The Beatles"],
        "opensearch_match" => true,
        "opensearch_score" => 18.5
      }
    )

    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {
        "title" => "Invalid Song",
        "artists" => ["John Lennon"],
        "mb_recording_id" => "abc123",
        "mb_recording_name" => "Wrong Version",
        "mb_artist_names" => ["John Lennon"],
        "musicbrainz_match" => true,
        "ai_match_invalid" => true
      }
    )

    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "Missing Song", "artists" => ["Unknown Artist"]}
    )

    @list.update!(wizard_state: {"current_step" => 4})

    Services::AuthenticationService.stubs(:validate_token).returns(@admin_user)
    login_as(@admin_user)
  end

  teardown do
    Capybara.app_host = nil
  end

  test "filter shows only valid items when selected" do
    visit step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    assert_selector "tr[data-status]", count: 3

    select "Valid Only", from: "status-filter"

    assert_selector "tr[data-status='valid']:not(.hidden)", count: 1
    assert_selector "tr[data-status='invalid'].hidden", count: 1
    assert_selector "tr[data-status='missing'].hidden", count: 1
  end

  test "filter shows only invalid items when selected" do
    visit step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    select "Invalid Only", from: "status-filter"

    assert_selector "tr[data-status='invalid']:not(.hidden)", count: 1
    assert_selector "tr[data-status='valid'].hidden", count: 1
    assert_selector "tr[data-status='missing'].hidden", count: 1
  end

  test "filter shows only missing items when selected" do
    visit step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    select "Missing Only", from: "status-filter"

    assert_selector "tr[data-status='missing']:not(.hidden)", count: 1
    assert_selector "tr[data-status='valid'].hidden", count: 1
    assert_selector "tr[data-status='invalid'].hidden", count: 1
  end

  test "filter shows all items when show all selected" do
    visit step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    select "Invalid Only", from: "status-filter"
    assert_selector "tr[data-status].hidden", count: 2

    select "Show All", from: "status-filter"
    assert_no_selector "tr[data-status].hidden"
    assert_selector "tr[data-status]", count: 3
  end

  test "visible count updates after filtering" do
    visit step_admin_songs_list_wizard_path(list_id: @list.id, step: "review")

    assert_text "Showing 3 items"

    select "Valid Only", from: "status-filter"
    assert_text "Showing 1 items"

    select "Invalid Only", from: "status-filter"
    assert_text "Showing 1 items"

    select "Missing Only", from: "status-filter"
    assert_text "Showing 1 items"

    select "Show All", from: "status-filter"
    assert_text "Showing 3 items"
  end

  private

  def login_as(user)
    page.set_rack_session(user_id: user.id)
  end
end
