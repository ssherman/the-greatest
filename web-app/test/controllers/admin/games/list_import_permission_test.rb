# frozen_string_literal: true

require "test_helper"

# Security audit M4. ListItemsActions and BaseListWizardController had no
# write or delete check, so a domain viewer could change and delete import data.
class Admin::Games::ListImportPermissionTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:games]
    @list = lists(:games_list)
    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Games::Game",
      verified: false,
      position: 1,
      metadata: {"title" => "Pokémon Go", "rank" => 1}
    )
    @viewer = users(:contractor_user)     # games viewer
    @editor = users(:games_editor_user)
    @moderator = users(:games_moderator_user)
  end

  # --- viewer: reads work ---

  test "viewer can open a wizard step" do
    sign_in_as(@viewer, stub_auth: true)
    get step_admin_games_list_wizard_path(list_id: @list.id, step: "source")
    assert_response :success
  end

  test "viewer can poll step status" do
    sign_in_as(@viewer, stub_auth: true)
    get step_status_admin_games_list_wizard_path(list_id: @list.id, step: "parse", format: :json)
    assert_response :success
  end

  test "viewer can open an item modal" do
    sign_in_as(@viewer, stub_auth: true)
    get modal_admin_games_list_item_path(list_id: @list.id, id: @item.id, modal_type: "edit_metadata")
    assert_response :success
  end

  # --- viewer: writes and deletes are refused ---

  test "viewer cannot verify an item" do
    sign_in_as(@viewer, stub_auth: true)
    post verify_admin_games_list_item_path(list_id: @list.id, id: @item.id)

    assert_redirected_to games_root_path
    refute @item.reload.verified?
  end

  test "viewer cannot save wizard html" do
    sign_in_as(@viewer, stub_auth: true)
    post save_html_admin_games_list_wizard_path(list_id: @list.id), params: {raw_content: "<p>injected</p>"}

    assert_redirected_to games_root_path
    refute_equal "<p>injected</p>", @list.reload.raw_content
  end

  test "viewer cannot delete an item" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete admin_games_list_item_path(list_id: @list.id, id: @item.id)
    end
    assert_redirected_to games_root_path
  end

  test "viewer cannot bulk delete" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete bulk_delete_admin_games_list_items_path(list_id: @list.id), params: {item_ids: [@item.id]}
    end
    assert_redirected_to games_root_path
  end

  test "viewer cannot restart the wizard" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      post restart_admin_games_list_wizard_path(list_id: @list.id)
    end
    assert_redirected_to games_root_path
  end

  # --- editor: writes work, deletes are refused ---

  test "editor can verify an item" do
    sign_in_as(@editor, stub_auth: true)
    post verify_admin_games_list_item_path(list_id: @list.id, id: @item.id)

    assert @item.reload.verified?
  end

  test "editor cannot delete an item" do
    sign_in_as(@editor, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete admin_games_list_item_path(list_id: @list.id, id: @item.id)
    end
    assert_redirected_to games_root_path
  end

  test "editor cannot reparse (it deletes unverified items)" do
    sign_in_as(@editor, stub_auth: true)

    assert_no_difference "ListItem.count" do
      post reparse_admin_games_list_wizard_path(list_id: @list.id)
    end
    assert_redirected_to games_root_path
  end

  # --- moderator: deletes work ---

  test "moderator can delete an item" do
    sign_in_as(@moderator, stub_auth: true)

    assert_difference "ListItem.count", -1 do
      delete admin_games_list_item_path(list_id: @list.id, id: @item.id)
    end
  end
end
