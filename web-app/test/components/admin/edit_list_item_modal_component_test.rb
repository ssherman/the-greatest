require "test_helper"

class Admin::EditListItemModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @album_list = lists(:music_albums_list)
    @album = music_albums(:dark_side_of_the_moon)

    @album_list.list_items.destroy_all
    @list_item = ListItem.create!(
      list: @album_list,
      listable: @album,
      position: 1,
      verified: true,
      metadata: {custom_field: "value"}
    )
  end

  test "renders modal with form" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))

    assert_selector "dialog#edit_list_item_modal_dialog_#{@list_item.id}"
    assert_selector "h3", text: "Edit List Item"
    assert_selector "form[action='#{admin_list_item_path(@list_item)}']"
  end

  test "shows item name as read-only" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))

    assert_selector "div.input", text: @album.title
  end

  test "pre-fills current position value" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))

    assert_selector "input[name='list_item[position]'][value='1']"
  end

  test "pre-fills current verified value" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))

    assert_selector "input[name='list_item[verified]'][type='checkbox'][checked]"
  end

  test "includes position input" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))
    assert_selector "input[name='list_item[position]'][type='number']"
  end

  test "includes metadata textarea" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))
    assert_selector "textarea[name='list_item[metadata]']"
  end

  test "includes verified checkbox" do
    render_inline(Admin::EditListItemModalComponent.new(list_item: @list_item))
    assert_selector "input[name='list_item[verified]'][type='checkbox']"
  end

  test "item_display_name returns title for albums" do
    component = Admin::EditListItemModalComponent.new(list_item: @list_item)
    assert_equal @album.title, component.item_display_name
  end

  test "metadata_json returns pretty JSON" do
    component = Admin::EditListItemModalComponent.new(list_item: @list_item)
    assert_includes component.metadata_json, "custom_field"
  end
end
