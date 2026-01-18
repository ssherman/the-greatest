require "test_helper"

class Admin::DomainRolesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @contractor = users(:contractor_user)
    @regular_user = users(:regular_user)

    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)
  end

  # Index tests
  test "should get index for user" do
    get admin_user_domain_roles_url(@contractor)
    assert_response :success
  end

  test "should show existing domain roles for user" do
    get admin_user_domain_roles_url(@contractor)
    assert_response :success
  end

  # Create tests
  test "should create domain role" do
    assert_difference("DomainRole.count") do
      post admin_user_domain_roles_url(@regular_user), params: {
        domain_role: {
          domain: "books",
          permission_level: "editor"
        }
      }
    end
    assert_redirected_to admin_user_domain_roles_url(@regular_user)
  end

  test "should not create duplicate domain role" do
    # contractor_user already has music role
    assert_no_difference("DomainRole.count") do
      post admin_user_domain_roles_url(@contractor), params: {
        domain_role: {
          domain: "music",
          permission_level: "viewer"
        }
      }
    end
    assert_redirected_to admin_user_domain_roles_url(@contractor)
    assert_includes flash[:alert], "already has a role for this domain"
  end

  # Update tests
  test "should update domain role permission level" do
    music_role = domain_roles(:music_editor)
    patch admin_user_domain_role_url(@contractor, music_role), params: {
      domain_role: {
        permission_level: "moderator"
      }
    }
    assert_redirected_to admin_user_domain_roles_url(@contractor)
    music_role.reload
    assert_equal "moderator", music_role.permission_level
  end

  # Destroy tests
  test "should destroy domain role" do
    music_role = domain_roles(:music_editor)
    assert_difference("DomainRole.count", -1) do
      delete admin_user_domain_role_url(@contractor, music_role)
    end
    assert_redirected_to admin_user_domain_roles_url(@contractor)
  end

  # Authorization tests
  test "should allow admin access" do
    get admin_user_domain_roles_url(@contractor)
    assert_response :success
  end

  test "should deny editor access" do
    sign_in_as(@editor, stub_auth: true)
    get admin_user_domain_roles_url(@contractor)
    assert_redirected_to music_root_url
  end

  test "should deny regular user access" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_user_domain_roles_url(@contractor)
    assert_redirected_to music_root_url
  end

  test "should deny unauthenticated access" do
    reset!
    host! Rails.application.config.domains[:music]
    get admin_user_domain_roles_url(@contractor)
    assert_redirected_to music_root_url
  end
end
