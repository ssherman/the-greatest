# frozen_string_literal: true

require "test_helper"

class Admin::AttachPenaltyModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @music_list = lists(:music_albums_list)
    @global_penalty = penalties(:global_penalty)
    @music_penalty = ::Music::Penalty.create!(name: "Static Music Penalty", description: "A static music penalty")
    @books_penalty = Books::Penalty.create!(name: "Static Books Penalty", description: "A static books penalty")

    # Clean up existing penalties
    ListPenalty.where(list: @music_list).destroy_all
  end

  test "component renders modal with form" do
    render_inline(Admin::AttachPenaltyModalComponent.new(list: @music_list))

    assert_selector "dialog#attach_penalty_modal_dialog"
    assert_selector "form[action='#{admin_list_list_penalties_path(@music_list)}']"
    assert_selector "select#list_penalty_penalty_id"
  end

  test "available_penalties returns only static penalties" do
    component = Admin::AttachPenaltyModalComponent.new(list: @music_list)

    penalties = component.available_penalties

    # Should only include static penalties
    assert penalties.all?(&:static?)
    assert_not penalties.any?(&:dynamic?)
  end

  test "available_penalties filters by media type" do
    component = Admin::AttachPenaltyModalComponent.new(list: @music_list)

    penalties = component.available_penalties
    penalty_types = penalties.map(&:type).uniq

    # Should only include Global and Music penalties
    assert penalty_types.all? { |t| t == "Global::Penalty" || t.start_with?("Music::") }
    assert_not penalty_types.any? { |t| t.start_with?("Books::") }
  end

  test "available_penalties excludes already attached penalties" do
    # Attach a penalty
    ListPenalty.create!(list: @music_list, penalty: @global_penalty)

    component = Admin::AttachPenaltyModalComponent.new(list: @music_list)
    penalties = component.available_penalties

    # Should not include already attached penalty
    assert_not penalties.include?(@global_penalty)
  end
end
