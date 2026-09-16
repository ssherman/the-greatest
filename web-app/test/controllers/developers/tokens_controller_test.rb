require "test_helper"

module Developers
  class TokensControllerTest < ActionDispatch::IntegrationTest
    TURBO = {"Accept" => "text/vnd.turbo-stream.html, text/html"}.freeze

    setup { host! Rails.application.config.domains[:books].to_s.split(",").first }

    def cap = Rails.application.config.x.api.max_tokens_per_user

    # --- index and the gate -------------------------------------------------

    test "a member sees the page" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      assert_response :success
    end

    test "a comped member sees the page" do
      sign_in_as(users(:editor_user), stub_auth: true)

      get developers_tokens_path

      assert_response :success
    end

    test "a signed-in non-member is redirected to the membership page" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)

      get developers_tokens_path

      assert_redirected_to membership_path
      assert_equal "That page is for members. Membership covers every site.", flash[:alert]
    end

    test "a signed-out visitor is redirected to the membership page" do
      get developers_tokens_path

      assert_redirected_to membership_path
      assert_equal "Sign in to your membership to open that page.", flash[:alert]
    end

    test "a member whose comp has expired is redirected" do
      sign_in_as(users(:user_with_expired_comp), stub_auth: true)

      get developers_tokens_path

      assert_redirected_to membership_path
    end

    test "the page is never cached" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      assert_includes response.headers["Cache-Control"], "no-store"
    end

    test "lists only the signed-in member's tokens" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      users(:regular_user).api_tokens.each do |token|
        assert_select "[id=?]", dom_id(token), 1
      end
      assert_select "[id=?]", dom_id(api_tokens(:non_member_token)), count: 0
    end

    test "each listed token has a revoke form and no secret" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      users(:regular_user).api_tokens.each do |token|
        assert_select "form[action=?][method=post] input[name=_method][value=delete]", developers_token_path(token)
      end
      assert_no_match(/tg_[A-Za-z0-9]{40}/, response.body)
    end

    test "the create form offers exactly the member-mintable scopes and the four expiries" do
      sign_in_as(users(:editor_user), stub_auth: true)

      get developers_tokens_path

      assert_select "form[action=?]", developers_tokens_path do
        assert_select "input[name='api_token[name]']", 1
        Api::Scopes.mintable_by(users(:editor_user)).each do |scope|
          assert_select "input[type=checkbox][name='api_token[scopes][]'][value=?][checked]", scope, 1
        end
        assert_select "input[type=checkbox][name='api_token[scopes][]']", Api::Scopes.mintable_by(users(:editor_user)).size
        assert_select "select[name='api_token[expires_in]'] option", 4
        assert_select "select[name='api_token[expires_in]'] option[value='']", 1
        TokensController::EXPIRY_DAYS.each do |days|
          assert_select "select[name='api_token[expires_in]'] option[value=?]", days.to_s, 1
        end
      end
    end

    test "every form control has a label" do
      sign_in_as(users(:editor_user), stub_auth: true)

      get developers_tokens_path

      css_select("form[action='#{developers_tokens_path}'] input:not([type=hidden]):not([type=submit]), form[action='#{developers_tokens_path}'] select").each do |control|
        id = control["id"]
        assert id.present?, "control #{control["name"]} has no id"
        labelled = css_select("label[for='#{id}']").any? || control["aria-label"].present?
        assert labelled, "control ##{id} has neither a <label for> nor an aria-label"
      end
    end

    test "at the cap the form is replaced by a notice" do
      user = users(:editor_user)
      cap.times { |i| Services::Api::Tokens.generate(user: user, name: "t#{i}", scopes: ["books:read"]) }
      sign_in_as(user, stub_auth: true)

      get developers_tokens_path

      assert_response :success
      assert_select "form[action=?]", developers_tokens_path, count: 0
      assert_select "[data-testid=token-cap-reached]", 1
    end
  end
end
