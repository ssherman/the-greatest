require "test_helper"

class Admin::EditListItemFormComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @album_list = lists(:music_albums_list)
    @album = music_albums(:animals)

    @list_item = ListItem.create!(
      list: @album_list,
      listable: @album,
      position: 1,
      verified: true,
      metadata: {custom_field: "value"}
    )
  end

  test "renders the edit form inside the shared modal frame" do
    list_item = list_items(:music_albums_item)

    render_inline(Admin::EditListItemFormComponent.new(list_item: list_item))

    assert_selector "turbo-frame##{Admin::EditListItemModalComponent::FRAME_ID}"
    assert_selector "input[name='list_item[position]']"
    assert_no_selector "dialog"
  end

  test "renders form targeting the list item" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))

    assert_selector "h3", text: "Edit List Item"
    assert_selector "form[action='#{admin_list_item_path(@list_item)}']"
  end

  test "shows autocomplete for album list items" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))

    assert_selector "label", text: "Current: #{@album.title}"
    assert_selector "input[name='list_item[listable_id]']", visible: :all
    assert_selector "input[type='search']"
  end

  test "pre-fills current position value" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))

    assert_selector "input[name='list_item[position]'][value='1']"
  end

  test "pre-fills current verified value" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))

    assert_selector "input[name='list_item[verified]'][type='checkbox'][checked]"
  end

  test "includes metadata textarea" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))
    assert_selector "textarea[name='list_item[metadata]']"
  end

  test "cancel button closes the constant dialog id" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))

    assert_selector "button[onclick='#{Admin::EditListItemModalComponent::DIALOG_ID}.close()']"
  end

  test "modal_form_modal_id_value matches the shell's DIALOG_ID" do
    render_inline(Admin::EditListItemFormComponent.new(list_item: @list_item))

    assert_selector "form[data-modal-form-modal-id-value='#{Admin::EditListItemModalComponent::DIALOG_ID}']"
  end

  test "item_display_name returns title for albums" do
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)
    assert_equal @album.title, component.item_display_name
  end

  test "unverified_item_display_name falls back to position when no metadata" do
    @list_item.update!(listable: nil, metadata: nil)
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)

    assert_equal "Unverified Item ##{@list_item.position}", component.unverified_item_display_name
  end

  test "unverified_item_display_name prefers metadata title" do
    @list_item.update!(listable: nil, metadata: {"title" => "Some Title"})
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)

    assert_equal "Some Title", component.unverified_item_display_name
  end

  test "item_label reads from domain routing config" do
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)
    assert_equal "Album", component.item_label
  end

  test "autocomplete_url reads from domain routing config" do
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)
    assert component.autocomplete_url.present?
  end

  test "metadata_json returns pretty JSON" do
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)
    assert_includes component.metadata_json, "custom_field"
  end

  test "metadata_json returns blank string when metadata is absent" do
    @list_item.update!(metadata: nil)
    component = Admin::EditListItemFormComponent.new(list_item: @list_item)
    assert_equal "", component.metadata_json
  end
end
