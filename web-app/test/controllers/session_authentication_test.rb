require "test_helper"

# Resolves current_user on a response the edge may cache, the way a cacheable
# page does when something in it asks who is signed in. Layouts no longer do.
class SessionGuardProbeController < ApplicationController
  include Cacheable

  def show
    skip_session_for_caching
    current_user
    render plain: "ok"
  end
end

# Writes the pre-migration identity key, to prove nothing reads it any more.
class LegacySessionProbeController < ApplicationController
  def show
    session[:user_id] = params.require(:id)
    render plain: "ok"
  end
end

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

    captured = cookies[:tg_session]

    with_routing do |set|
      # with_routing starts a fresh integration session, so carry the cookie over.
      cookies[:tg_session] = captured
      set.draw { get "/session_guard_probe", to: "session_guard_probe#show" }
      get "/session_guard_probe"
      assert_response :success
      assert_empty set_cookie_lines
    end
  end

  test "a legacy session[:user_id] no longer signs anyone in" do
    with_routing do |set|
      set.draw do
        get "/legacy_session_probe", to: "legacy_session_probe#show"
        get "/user_list_state", to: "user_list_state#show"
      end
      get "/legacy_session_probe", params: {id: @user.id}
      assert_response :success

      get "/user_list_state", as: :json
      assert_response :unauthorized
    end
  end

  test "a signed-in page re-sets tg_uid when only tg_session survived" do
    sign_in_as(@user, stub_auth: true)
    cookies[:tg_uid] = ""
    assert cookies[:tg_uid].blank?

    get my_lists_path

    assert_response :success
    assert_equal @user.id.to_s, cookies[:tg_uid]
  end

  test "tg_session is HttpOnly and tg_uid is JS-readable, both SameSite=Lax" do
    sign_in_as(@user, stub_auth: true)

    session_line = set_cookie_lines.find { |l| l.start_with?("tg_session=") }
    uid_line = set_cookie_lines.find { |l| l.start_with?("tg_uid=") }
    assert_match(/httponly/i, session_line)
    assert_match(/samesite=lax/i, session_line)
    assert_match(/samesite=lax/i, uid_line)
    assert_no_match(/httponly/i, uid_line)
  end

  test "a tg_session pointing at a deleted row is cleared on an uncached request" do
    sign_in_as(@user, stub_auth: true)
    Session.delete_all

    get "/user_list_state", as: :json

    assert_response :unauthorized
    %w[tg_session tg_uid].each do |name|
      line = set_cookie_lines.find { |l| l.start_with?("#{name}=") }
      assert line, "expected #{name} to be deleted"
      assert Time.httpdate(line[/expires=([^;]+)/i, 1]) < Time.current
    end
  end

  test "a tg_session pointing at a deleted row sets no cookie on a cacheable page" do
    sign_in_as(@user, stub_auth: true)
    Session.delete_all

    captured = cookies[:tg_session]

    with_routing do |set|
      # with_routing starts a fresh integration session, so carry the cookie over.
      cookies[:tg_session] = captured
      set.draw { get "/session_guard_probe", to: "session_guard_probe#show" }
      get "/session_guard_probe"
      assert_response :success
      assert_empty set_cookie_lines
    end
  end

  test "signing in again on the same browser destroys the previous session row" do
    sign_in_as(@user, stub_auth: true)
    first = Session.find_by!(user: @user)

    sign_in_as(@user, stub_auth: true)

    assert_not Session.exists?(first.id)
    assert_equal 1, @user.sessions.count
  end

  test "user_list_state renews a session last active more than a day ago" do
    sign_in_as(@user, stub_auth: true)
    row = Session.find_by!(user: @user)
    created = row.created_at

    travel 2.days do
      get "/user_list_state", as: :json

      assert_response :success
      assert_in_delta Time.current.to_i, row.reload.last_active_at.to_i, 5
      assert_equal created.to_i, row.created_at.to_i
      %w[tg_session tg_uid].each do |name|
        line = set_cookie_lines.find { |l| l.start_with?("#{name}=") }
        assert line, "expected a renewed #{name} cookie"
        expires = Time.httpdate(line[/expires=([^;]+)/i, 1])
        assert_in_delta (Time.current + Session::IDLE_TIMEOUT).to_i, expires.to_i, 5
      end
    end
  end

  test "user_list_state does not renew a session active within the last day" do
    sign_in_as(@user, stub_auth: true)
    get "/user_list_state", as: :json
    row = Session.find_by!(user: @user)
    before = row.last_active_at

    travel 1.hour do
      get "/user_list_state", as: :json

      assert_response :success
      assert_equal before.to_i, row.reload.last_active_at.to_i
      assert_nil set_cookie_lines.find { |l| l.start_with?("tg_session=") }
    end
  end

  test "renewal never extends past the one-year hard limit" do
    sign_in_as(@user, stub_auth: true)
    limit = Session.find_by!(user: @user).created_at + Session::MAX_LIFETIME

    travel_to Time.current do
      5.times do
        travel 80.days
        get "/user_list_state", as: :json
        break unless response.successful?

        line = set_cookie_lines.find { |l| l.start_with?("tg_session=") }
        assert line, "expected renewal at #{Time.current}"
        assert_operator Time.httpdate(line[/expires=([^;]+)/i, 1]).to_i, :<=, limit.to_i
      end

      travel_to limit + 1.day
      get "/user_list_state", as: :json
      assert_response :unauthorized
    end
  end

  test "an admin page renews a session last active more than a day ago" do
    host! Rails.application.config.domains[:music]
    admin = users(:admin_user)
    sign_in_as(admin, stub_auth: true)
    row = Session.find_by!(user: admin)

    travel 2.days do
      get admin_user_domain_roles_path(@user)

      assert_response :success
      assert_in_delta Time.current.to_i, row.reload.last_active_at.to_i, 5
    end
  end
end
