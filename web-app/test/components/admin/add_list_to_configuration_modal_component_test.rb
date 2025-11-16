# frozen_string_literal: true

require "test_helper"

class Admin::AddListToConfigurationModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @albums_config = ranking_configurations(:music_albums_global)
    @songs_config = ranking_configurations(:music_songs_global)
    @album_list = lists(:music_albums_list)
    @song_list = lists(:music_songs_list)

    RankedList.where(ranking_configuration: @albums_config).destroy_all
    RankedList.where(ranking_configuration: @songs_config).destroy_all
  end

  test "component renders modal with form" do
    render_inline(Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @albums_config))

    assert_selector "dialog#add_list_to_configuration_modal_dialog"
    assert_selector "form[action='#{admin_ranking_configuration_ranked_lists_path(@albums_config)}']"
    assert_selector "select#ranked_list_list_id"
  end

  test "available_lists returns filtered lists" do
    component = Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @albums_config)

    lists = component.available_lists

    assert lists.any?
    assert lists.include?(@album_list)
  end

  test "available_lists filters by media type" do
    component = Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @albums_config)

    lists = component.available_lists
    list_types = lists.map(&:type).uniq

    assert list_types.all? { |t| t == "Music::Albums::List" }
    assert_not lists.include?(@song_list)
  end

  test "available_lists excludes already added lists" do
    RankedList.create!(ranking_configuration: @albums_config, list: @album_list)

    component = Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @albums_config)
    lists = component.available_lists

    assert_not lists.include?(@album_list)
  end

  test "component includes list selector with name and source display" do
    render_inline(Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @albums_config))

    assert_selector "select#ranked_list_list_id"
    assert_match @album_list.name, page.native.to_s
  end

  test "available_lists displays newest lists first" do
    old_list = List.create!(
      type: "Music::Albums::List",
      name: "Old List",
      status: :approved,
      created_at: 10.days.ago
    )
    new_list = List.create!(
      type: "Music::Albums::List",
      name: "New List",
      status: :approved,
      created_at: Time.current
    )

    component = Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @albums_config)
    lists = component.available_lists

    new_index = lists.index(new_list)
    old_index = lists.index(old_list)

    assert new_index < old_index, "Expected new_list at index #{new_index} to come before old_list at index #{old_index}"
  end
end
