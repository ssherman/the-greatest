require "test_helper"

class Admin::Music::Songs::Wizard::EditMetadataModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @list = lists(:music_songs_list)
    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Come Together", "artists" => ["The Beatles"], "rank" => 1}
    )
  end

  test "renders modal with correct id" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "div#edit_metadata_modal_#{@item.id}"
    assert_selector "dialog#edit_metadata_modal_#{@item.id}_dialog"
  end

  test "renders modal title" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "h3", text: "Edit Metadata"
  end

  test "renders item label with position, title and artists" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_text "#1 - \"Come Together\" by The Beatles"
  end

  test "renders form with correct action and method" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "form[action='#{metadata_admin_songs_list_item_path(list_id: @list.id, id: @item.id)}']"
    assert_selector "form input[name='_method'][value='patch']", visible: false
  end

  test "renders textarea with formatted JSON" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "textarea[name='list_item[metadata_json]']"
  end

  test "renders error container" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "div#edit_metadata_modal_#{@item.id}_error"
  end

  test "renders cancel and save buttons" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "button", text: "Cancel"
    assert_selector "input[type='submit'][value='Save']"
  end

  test "includes metadata-editor stimulus controller" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "form[data-controller~='metadata-editor']"
  end

  test "includes modal-form stimulus controller" do
    render_inline(Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item))

    assert_selector "form[data-controller~='modal-form']"
  end

  test "modal_id returns correct format" do
    component = Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item)
    assert_equal "edit_metadata_modal_#{@item.id}", component.send(:modal_id)
  end

  test "formatted_metadata returns pretty JSON" do
    component = Admin::Music::Songs::Wizard::EditMetadataModalComponent.new(list_item: @item)
    formatted = component.send(:formatted_metadata)

    assert_includes formatted, "\"title\": \"Come Together\""
    assert JSON.parse(formatted)
  end
end
