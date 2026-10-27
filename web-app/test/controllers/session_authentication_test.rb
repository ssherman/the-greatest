require "test_helper"

class SessionAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev.thegreatest.games"
    @user = users(:regular_user)
    Session.delete_all
  end

  def set_cookie_lines
    Array(response.headers["Set-Cookie"]).flat_map { |h| h.to_s.split("\n") }
  end

  test "sign in creates one Session row for the user and sets tg_session and tg_uid" do
    assert_difference -> { @user.sessions.count }, 1 do
      sign_in_as(@user, stub_auth: true)
    end

    assert_response :success
    assert cookies[:tg_session].present?
    assert_equal @user.id.to_s, cookies[:tg_uid]
  end

  test "tg_uid and tg_session expire at the session's expiry" do
    freeze_time do
      sign_in_as(@user, stub_auth: true)

      %w[tg_session tg_uid].each do |name|
        line = set_cookie_lines.find { |l| l.start_with?("#{name}=") }
        assert line, "expected a #{name} Set-Cookie"
        expires = Time.httpdate(line[/expires=([^;]+)/i, 1])
        assert_in_delta (Time.current + Session::IDLE_TIMEOUT).to_i, expires.to_i, 5
      end
    end
  end

  test "a request with a valid tg_session resolves current_user" do
    sign_in_as(@user, stub_auth: true)

    get "/user_list_state", as: :json

    assert_response :success
  end

  test "deleting the Session row signs the browser out" do
    sign_in_as(@user, stub_auth: true)
    Session.delete_all

    get "/user_list_state", as: :json

    assert_response :unauthorized
  end

  test "sign out destroys only this browser's session" do
    sign_in_as(@user, stub_auth: true)
    mine = Session.find_by!(user: @user)
    other = Session.create!(user: @user, last_active_at: Time.current)

    post auth_sign_out_path, as: :json

    assert_response :success
    assert_not Session.exists?(mine.id)
    assert Session.exists?(other.id)
  end

  test "an old tg_session cookie replayed after sign out is rejected" do
    sign_in_as(@user, stub_auth: true)
    captured = cookies[:tg_session]

    post auth_sign_out_path, as: :json
    cookies[:tg_session] = captured
    get "/user_list_state", as: :json

    assert_response :unauthorized
  end

  # The signed cookie carries its own expiry, so a browser idle past it never
  # reaches the row (the prune job removes that). These tests age the row alone,
  # as when the cookie is still valid but the row is past its limit.
  test "an expired session is destroyed and treated as signed out" do
    sign_in_as(@user, stub_auth: true)
    Session.update_all(last_active_at: 91.days.ago)

    get "/user_list_state", as: :json

    assert_response :unauthorized
    assert_equal 0, Session.count
  end

  test "a session past its one-year limit is rejected even if recently active" do
    sign_in_as(@user, stub_auth: true)
    Session.update_all(created_at: 366.days.ago)

    get "/user_list_state", as: :json

    assert_response :unauthorized
    assert_equal 0, Session.count
  end

  test "a cacheable page sets no cookie for a visitor whose session has expired" do
    sign_in_as(@user, stub_auth: true)
    Session.update_all(last_active_at: 91.days.ago)

    get game_path(games_games(:breath_of_the_wild))

    assert_response :success
    assert_includes response.headers["Cache-Control"], "public"
    assert_empty set_cookie_lines
  end
end
