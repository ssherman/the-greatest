require "test_helper"
require "rake"

class ApiRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("api:service_account:create")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/api.rake").to_s }
    end
    %w[api:service_account:create api:service_account:token api:token:revoke].each { |name| Rake::Task[name].reenable }
  end

  test "service_account:create prints exactly the secret" do
    out, _err = with_env("NAME" => "rake-made", "SCOPES" => "books:read,games:read") do
      capture_io { Rake::Task["api:service_account:create"].invoke }
    end

    secret = out.strip
    assert_match ApiToken::SECRET_FORMAT, secret
    assert_equal 1, out.lines.size
    token = ApiToken.authenticate(secret)
    assert_equal ["books:read", "games:read"], token.scopes
    assert_equal "rake-made@service-accounts.thegreatest.invalid", token.user.email
  end

  test "service_account:create aborts with the validation message on bad input" do
    with_env("NAME" => "Bad Name", "SCOPES" => "books:read") do
      error = assert_raises(SystemExit) { capture_io { Rake::Task["api:service_account:create"].invoke } }
      assert_match(/NAME/, error.message)
    end
  end

  test "service_account:token mints another token for an existing account" do
    out, _err = with_env("NAME" => "agent-runner", "TOKEN_NAME" => "prod-2", "SCOPES" => "books:read") do
      capture_io { Rake::Task["api:service_account:token"].invoke }
    end

    token = ApiToken.authenticate(out.strip)
    assert_equal users(:agent_runner_service_account), token.user
    assert_equal "prod-2", token.name
  end

  test "token:revoke destroys the token" do
    id = api_tokens(:service_account_token).id

    assert_difference "ApiToken.count", -1 do
      with_env("ID" => id.to_s) { capture_io { Rake::Task["api:token:revoke"].invoke } }
    end
  end
end
