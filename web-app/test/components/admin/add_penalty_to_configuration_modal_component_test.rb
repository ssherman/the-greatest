# frozen_string_literal: true

require "test_helper"

class Admin::AddPenaltyToConfigurationModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @music_config = ranking_configurations(:music_albums_global)
    @global_penalty = penalties(:global_penalty)
    @music_penalty = penalties(:music_penalty)
    @books_penalty = penalties(:books_penalty)

    PenaltyApplication.where(ranking_configuration: @music_config).destroy_all
  end

  test "component renders modal with form" do
    render_inline(Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @music_config))

    assert_selector "dialog#add_penalty_to_configuration_modal_dialog"
    assert_selector "form[action='#{admin_ranking_configuration_penalty_applications_path(@music_config)}']"
    assert_selector "select#penalty_application_penalty_id"
  end

  test "component includes value input field" do
    render_inline(Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @music_config))

    assert_selector "input#penalty_application_value[type='number']"
    assert_selector "input[min='0'][max='100']"
  end

  test "available_penalties returns filtered penalties" do
    component = Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @music_config)

    penalties = component.available_penalties

    assert penalties.any?
  end

  test "available_penalties filters by media type" do
    component = Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @music_config)

    penalties = component.available_penalties
    penalty_types = penalties.map(&:type).uniq

    assert penalty_types.all? { |t| t == "Global::Penalty" || t.start_with?("Music::") }
    assert_not penalty_types.any? { |t| t.start_with?("Books::") }
  end

  test "available_penalties excludes already applied penalties" do
    PenaltyApplication.create!(ranking_configuration: @music_config, penalty: @global_penalty, value: 75)

    component = Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @music_config)
    penalties = component.available_penalties

    assert_not penalties.include?(@global_penalty)
  end
end
