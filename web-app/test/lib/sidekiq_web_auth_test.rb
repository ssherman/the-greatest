require "test_helper"

class SidekiqWebAuthTest < ActiveSupport::TestCase
  def auth(username, password, expected_username:, expected_password:)
    SidekiqWebAuth.authenticate(username, password,
      expected_username: expected_username, expected_password: expected_password)
  end

  test "accepts the configured credentials" do
    assert auth("admin", "s3cret", expected_username: "admin", expected_password: "s3cret")
  end

  test "rejects a wrong password" do
    refute auth("admin", "nope", expected_username: "admin", expected_password: "s3cret")
  end

  test "rejects a wrong username" do
    refute auth("root", "s3cret", expected_username: "admin", expected_password: "s3cret")
  end

  test "rejects empty credentials when nothing is configured" do
    refute auth("", "", expected_username: nil, expected_password: nil)
    refute auth("", "", expected_username: "", expected_password: "")
  end

  test "rejects everything when only one credential is configured" do
    refute auth("admin", "", expected_username: "admin", expected_password: nil)
    refute auth("", "s3cret", expected_username: nil, expected_password: "s3cret")
    refute auth("admin", "anything", expected_username: "admin", expected_password: "  ")
  end

  test "tolerates a nil submitted credential" do
    refute auth(nil, nil, expected_username: "admin", expected_password: "s3cret")
  end
end
