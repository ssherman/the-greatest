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

  # Available domains tests
  # Regression test for bug where pluck(:domain) returns integers but
  # DomainRole.domains.keys returns strings, so subtraction never removes anything
  test "available_domains should exclude already assigned domains" do
    # contractor_user has music and games domain roles from fixtures
    get admin_user_domain_roles_url(@contractor)
    assert_response :success

    # The select options should NOT include music or games (already assigned)
    # The Grant New Role form uses: @available_domains.map { |d| [d.humanize, d] }
    assert_no_match(/<option[^>]*value="music"/, response.body, "Music should not be in available domains")
    assert_no_match(/<option[^>]*value="games"/, response.body, "Games should not be in available domains")

    # But should include other domains that aren't assigned
    assert_match(/<option[^>]*value="books"/, response.body, "Books should be available")
    assert_match(/<option[^>]*value="movies"/, response.body, "Movies should be available")
  end

  test "available_domains should be empty when user has all domain roles" do
    # Give the contractor the remaining domain roles (they already have music and games)
    DomainRole.create!(user: @contractor, domain: "books", permission_level: "viewer")
    DomainRole.create!(user: @contractor, domain: "movies", permission_level: "viewer")

    get admin_user_domain_roles_url(@contractor)
    assert_response :success

    # The "Grant New Role" form should not appear when no domains are available
    assert_no_match(/Grant New Role/, response.body, "Grant New Role form should not appear when user has all domains")
  end

  # Regression test: form must submit params nested under domain_role key
  test "form should submit params correctly nested under domain_role" do
    # Simulate what the form actually submits (without proper nesting)
    # This should fail if form doesn't have proper scope/model
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

  test "form inputs should have correct name attributes for params nesting" do
    get admin_user_domain_roles_url(@regular_user)
    assert_response :success

    # The form inputs should be named domain_role[domain] and domain_role[permission_level]
    # not just "domain" and "permission_level"
    assert_match(/name="domain_role\[domain\]"/, response.body, "Domain select should have name='domain_role[domain]'")
    assert_match(/name="domain_role\[permission_level\]"/, response.body, "Permission level select should have name='domain_role[permission_level]'")
  end
end
