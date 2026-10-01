# frozen_string_literal: true

require "test_helper"

# Security audit M4, music side. See Admin::Games::ListImportPermissionTest.
class Admin::Music::Albums::ListImportPermissionTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:music]
    @list = lists(:music_albums_list)
    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Music::Album",
      verified: false,
      position: 1,
      metadata: {"title" => "The Dark Side of the Moon", "artists" => ["Pink Floyd"], "rank" => 1}
    )
    @editor = users(:contractor_user)     # music editor

    @viewer = User.create!(email: "music.viewer@example.com", role: :user, email_verified: true)
    @viewer.domain_roles.create!(domain: :music, permission_level: :viewer)

    @moderator = User.create!(email: "music.moderator@example.com", role: :user, email_verified: true)
    @moderator.domain_roles.create!(domain: :music, permission_level: :moderator)
  end

  test "viewer can open a wizard step" do
    sign_in_as(@viewer, stub_auth: true)
    get step_admin_albums_list_wizard_path(list_id: @list.id, step: "source")
    assert_response :success
  end

  test "viewer cannot change item metadata" do
    sign_in_as(@viewer, stub_auth: true)
    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate({"title" => "Hacked", "rank" => 1})}}

    assert_redirected_to music_root_path
    assert_equal "The Dark Side of the Moon", @item.reload.metadata["title"]
  end

  test "viewer cannot advance the wizard" do
    sign_in_as(@viewer, stub_auth: true)
    post advance_step_admin_albums_list_wizard_path(list_id: @list.id, step: "source")

    assert_redirected_to music_root_path
  end

  test "viewer cannot bulk delete" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete bulk_delete_admin_albums_list_items_path(list_id: @list.id), params: {item_ids: [@item.id]}
    end
    assert_redirected_to music_root_path
  end

  test "editor can change item metadata but cannot delete" do
    sign_in_as(@editor, stub_auth: true)
    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate({"title" => "Fixed", "rank" => 1})}}
    assert_equal "Fixed", @item.reload.metadata["title"]

    assert_no_difference "ListItem.count" do
      delete admin_albums_list_item_path(list_id: @list.id, id: @item.id)
    end
    assert_redirected_to music_root_path
  end

  # Not "can bulk delete": DELETE .../items/bulk_delete is shadowed by the
  # member route .../items/:id and dispatches to #destroy (pre-existing).
  test "moderator can delete an item" do
    sign_in_as(@moderator, stub_auth: true)

    assert_difference "ListItem.count", -1 do
      delete admin_albums_list_item_path(list_id: @list.id, id: @item.id)
    end
  end
end
