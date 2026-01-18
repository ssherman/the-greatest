require "test_helper"

# Tests that ranking configurations require admin/manage permission.
# Global editors should NOT be able to create/update/delete ranking configs.
class Admin::Music::RankingConfigurationPermissionTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @ranking_config = ranking_configurations(:music_albums_global)

    # Create a domain admin user
    @domain_admin = User.create!(
      email: "domain_admin@example.com",
      name: "Domain Admin",
      role: :user,
      email_verified: true
    )
    @domain_admin.domain_roles.create!(domain: :music, permission_level: :admin)

    # Create a domain editor user (should NOT have manage access)
    @domain_editor = User.create!(
      email: "domain_editor@example.com",
      name: "Domain Editor",
      role: :user,
      email_verified: true
    )
    @domain_editor.domain_roles.create!(domain: :music, permission_level: :editor)

    host! Rails.application.config.domains[:music]
  end

  # Global admin should have full access

  test "global admin can view ranking configurations" do
    sign_in_as(@admin, stub_auth: true)
    get admin_albums_ranking_configurations_path
    assert_response :success
  end

  test "global admin can create ranking configuration" do
    sign_in_as(@admin, stub_auth: true)

    assert_difference("Music::Albums::RankingConfiguration.count") do
      post admin_albums_ranking_configurations_path, params: {
        ranking_configuration: {
          name: "Admin Created Config",
          global: true,
          primary: false
        }
      }
    end
  end

  # Global editor should NOT have manage access (only read/write, not manage)

  test "global editor can view ranking configurations" do
    sign_in_as(@editor, stub_auth: true)
    get admin_albums_ranking_configurations_path
    assert_response :success
  end

  test "global editor CANNOT create ranking configuration" do
    sign_in_as(@editor, stub_auth: true)

    assert_no_difference("Music::Albums::RankingConfiguration.count") do
      post admin_albums_ranking_configurations_path, params: {
        ranking_configuration: {
          name: "Editor Created Config",
          global: true,
          primary: false
        }
      }
    end

    assert_redirected_to music_root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
  end

  test "global editor CANNOT update ranking configuration" do
    sign_in_as(@editor, stub_auth: true)
    original_name = @ranking_config.name

    patch admin_albums_ranking_configuration_path(@ranking_config), params: {
      ranking_configuration: {name: "Hacked Name"}
    }

    assert_redirected_to music_root_path
    @ranking_config.reload
    assert_equal original_name, @ranking_config.name
  end

  test "global editor CANNOT delete ranking configuration" do
    sign_in_as(@editor, stub_auth: true)

    assert_no_difference("Music::Albums::RankingConfiguration.count") do
      delete admin_albums_ranking_configuration_path(@ranking_config)
    end

    assert_redirected_to music_root_path
  end

  # Domain admin should have manage access

  test "domain admin can create ranking configuration" do
    sign_in_as(@domain_admin, stub_auth: true)

    assert_difference("Music::Albums::RankingConfiguration.count") do
      post admin_albums_ranking_configurations_path, params: {
        ranking_configuration: {
          name: "Domain Admin Config",
          global: true,
          primary: false
        }
      }
    end
  end

  # Domain editor should NOT have manage access

  test "domain editor CANNOT create ranking configuration" do
    sign_in_as(@domain_editor, stub_auth: true)

    assert_no_difference("Music::Albums::RankingConfiguration.count") do
      post admin_albums_ranking_configurations_path, params: {
        ranking_configuration: {
          name: "Domain Editor Config",
          global: true,
          primary: false
        }
      }
    end

    assert_redirected_to music_root_path
  end
end
