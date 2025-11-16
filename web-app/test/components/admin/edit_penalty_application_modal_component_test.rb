# frozen_string_literal: true

require "test_helper"

class Admin::EditPenaltyApplicationModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @music_config = ranking_configurations(:music_albums_global)
    @global_penalty = penalties(:global_penalty)

    PenaltyApplication.where(ranking_configuration: @music_config).destroy_all

    @penalty_application = PenaltyApplication.create!(
      ranking_configuration: @music_config,
      penalty: @global_penalty,
      value: 75
    )
  end

  test "component renders modal with form" do
    render_inline(Admin::EditPenaltyApplicationModalComponent.new(penalty_application: @penalty_application))

    assert_selector "dialog#edit_penalty_application_modal_dialog_#{@penalty_application.id}"
    assert_selector "form[action='#{admin_penalty_application_path(@penalty_application)}']"
  end

  test "component shows penalty name as read-only" do
    render_inline(Admin::EditPenaltyApplicationModalComponent.new(penalty_application: @penalty_application))

    assert_selector "input[disabled][value='#{@penalty_application.penalty.name}']"
  end

  test "component pre-fills current value" do
    render_inline(Admin::EditPenaltyApplicationModalComponent.new(penalty_application: @penalty_application))

    assert_selector "input#penalty_application_value[value='75']"
  end

  test "component includes value input with correct attributes" do
    render_inline(Admin::EditPenaltyApplicationModalComponent.new(penalty_application: @penalty_application))

    assert_selector "input#penalty_application_value[type='number']"
    assert_selector "input[min='0'][max='100']"
  end
end
