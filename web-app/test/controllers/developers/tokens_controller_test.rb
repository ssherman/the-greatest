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

    # --- create -----------------------------------------------------------------

    def create_token(params, user: users(:editor_user))
      sign_in_as(user, stub_auth: true)
      post developers_tokens_path, params: {api_token: params}, headers: TURBO
    end

    def secret_in_body = response.body[/tg_[A-Za-z0-9]{40}/]

    test "a member creates a token and the secret is in the stream exactly once" do
      assert_difference -> { users(:editor_user).api_tokens.count }, 1 do
        create_token({name: "laptop", scopes: ["books:read", "music:read"], expires_in: ""})
      end

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      assert_equal 1, response.body.scan(/tg_[A-Za-z0-9]{40}/).size
      token = Services::Api::Tokens.authenticate(secret_in_body)
      assert_equal users(:editor_user), token.user
      assert_equal "laptop", token.name
      assert_equal ["books:read", "music:read"], token.scopes
      assert_nil token.expires_at
      assert_select "turbo-stream[action=update][target=developers_new_token] [data-testid=token-secret][value=?]", secret_in_body
      assert_select "turbo-stream[action=update][target=developers_new_token] [data-testid=new-token][data-turbo-temporary]"
      assert_select "turbo-stream[action=replace][target=developers_tokens] [id=?]", dom_id(token)
      assert_select "turbo-stream[action=replace][target=developers_token_form] form[action=?]", developers_tokens_path
    end

    test "the secret is not in the list, a redirect or the flash" do
      create_token({name: "laptop", scopes: ["books:read"], expires_in: ""})
      secret = secret_in_body

      assert_nil response.location
      assert_nil flash[:notice]
      assert_select "turbo-stream[target=developers_tokens]", text: /#{Regexp.escape(secret)}/, count: 0

      get developers_tokens_path
      assert_no_match(/#{Regexp.escape(secret)}/, response.body)
    end

    test "an expiry from the list sets expires_at" do
      freeze_time do
        create_token({name: "short", scopes: ["books:read"], expires_in: "30"})

        assert_equal 30.days.from_now, Services::Api::Tokens.authenticate(secret_in_body).expires_at
      end
    end

    test "an expiry not on the list is refused" do
      assert_no_difference -> { ApiToken.count } do
        create_token({name: "tampered", scopes: ["books:read"], expires_in: "7"})
      end

      assert_response :unprocessable_entity
      assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      assert_select "turbo-stream[action=replace][target=developers_token_form] [data-testid=token-form-error]"
      assert_select "turbo-stream[target=developers_new_token]", count: 0
    end

    test "no scopes is a 422 that keeps what was typed" do
      assert_no_difference -> { ApiToken.count } do
        create_token({name: "nothing", expires_in: "90"})
      end

      assert_response :unprocessable_entity
      assert_select "turbo-stream[target=developers_token_form] input[name='api_token[name]'][value=nothing]"
      assert_select "turbo-stream[target=developers_token_form] select[name='api_token[expires_in]'] option[value='90'][selected]"
      assert_select "turbo-stream[target=developers_token_form] input[type=checkbox][checked]", count: 0
    end

    test "a scope a member may not mint is a 422" do
      assert_no_difference -> { ApiToken.count } do
        create_token({name: "greedy", scopes: ["books:read", "books:admin"], expires_in: ""})
      end

      assert_response :unprocessable_entity
    end

    test "a blank name is a 422" do
      assert_no_difference -> { ApiToken.count } do
        create_token({name: "   ", scopes: ["books:read"], expires_in: ""})
      end

      assert_response :unprocessable_entity
    end

    test "the cap is enforced and the form becomes the notice" do
      user = users(:editor_user)
      (cap - 1).times { |i| Services::Api::Tokens.generate(user: user, name: "t#{i}", scopes: ["books:read"]) }

      create_token({name: "last", scopes: ["books:read"], expires_in: ""}, user: user)
      assert_response :success
      assert_select "turbo-stream[target=developers_token_form] [data-testid=token-cap-reached]"

      assert_no_difference -> { user.api_tokens.count } do
        post developers_tokens_path, params: {api_token: {name: "one too many", scopes: ["books:read"], expires_in: ""}}, headers: TURBO
      end
      assert_response :unprocessable_entity
    end

    test "a scalar api_token param is a 422, not a 500" do
      sign_in_as(users(:editor_user), stub_auth: true)

      post developers_tokens_path, params: {api_token: "junk"}, headers: TURBO

      assert_response :unprocessable_entity
    end

    test "create is never cached" do
      create_token({name: "laptop", scopes: ["books:read"], expires_in: ""})

      assert_includes response.headers["Cache-Control"], "no-store"
    end

    test "a non-member cannot create a token" do
      assert_no_difference -> { ApiToken.count } do
        create_token({name: "nope", scopes: ["books:read"], expires_in: ""}, user: users(:books_viewer_user))
      end

      assert_redirected_to membership_path
    end

    test "a signed-out visitor cannot create a token" do
      assert_no_difference -> { ApiToken.count } do
        post developers_tokens_path, params: {api_token: {name: "nope", scopes: ["books:read"], expires_in: ""}}, headers: TURBO
      end

      assert_redirected_to membership_path
    end

    # --- destroy ---------------------------------------------------------------

    test "a member revokes their own token and the list refreshes" do
      sign_in_as(users(:regular_user), stub_auth: true)
      token = api_tokens(:regular_user_token)

      assert_difference -> { users(:regular_user).api_tokens.count }, -1 do
        delete developers_token_path(token), headers: TURBO
      end

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      assert_select "turbo-stream[action=replace][target=developers_tokens] [id=?]", dom_id(token), count: 0
      assert_select "turbo-stream[action=replace][target=developers_tokens] [id=?]", dom_id(api_tokens(:regular_user_music_only_token))
      assert_select "turbo-stream[action=replace][target=developers_token_form]"
      assert_select "turbo-stream[target=developers_new_token]", count: 0
      assert_nil Services::Api::Tokens.authenticate(ApiTokenSecrets::MEMBER)
    end

    test "revoking below the cap brings the form back" do
      user = users(:editor_user)
      made = cap.times.map { |i| Services::Api::Tokens.generate(user: user, name: "t#{i}", scopes: ["books:read"]).data[:token] }
      sign_in_as(user, stub_auth: true)

      delete developers_token_path(made.first), headers: TURBO

      assert_select "turbo-stream[target=developers_token_form] form[action=?]", developers_tokens_path
      assert_select "turbo-stream[target=developers_token_form] [data-testid=token-cap-reached]", count: 0
    end

    test "a member cannot revoke another account's token" do
      sign_in_as(users(:regular_user), stub_auth: true)

      assert_no_difference -> { ApiToken.count } do
        delete developers_token_path(api_tokens(:non_member_token)), headers: TURBO
      end

      assert_response :not_found
    end

    test "a signed-out visitor cannot revoke" do
      assert_no_difference -> { ApiToken.count } do
        delete developers_token_path(api_tokens(:regular_user_token)), headers: TURBO
      end

      assert_redirected_to membership_path
    end

    test "destroy is never cached" do
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_token_path(api_tokens(:regular_user_token)), headers: TURBO

      assert_includes response.headers["Cache-Control"], "no-store"
    end
  end
end
