require "test_helper"

class Services::BooksMigration::UserMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::UserMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A fully-populated legacy users row (String keys, as record.attributes yields).
  def legacy_attrs(overrides = {})
    {
      "id" => 90001, "email" => "u90001@example.com", "name" => "Nine", "display_name" => "Niner",
      "photo_url" => "http://img/9.png", "auth_uid" => "fb-9", "auth_data" => {"uid" => "fb-9"},
      "provider_data" => "{\"2\":{\"providerId\":\"google.com\"}}", "email_verified" => true,
      "external_provider" => 2, "role" => 0, "sign_in_count" => 3,
      "last_sign_in_at" => Time.utc(2020, 1, 1), "stripe_customer_id" => nil,
      "external_provider_uid" => "100005840193753", "migrated" => true,
      "old_user_data" => "{\"id\":\"90001\",\"provider\":\"facebook\"}",
      "created_at" => Time.utc(2015, 4, 28, 5, 28, 51), "updated_at" => Time.utc(2016, 1, 1)
    }.merge(overrides)
  end

  test "maps a legacy user to the new columns, preserving id and enums" do
    result = run_migrator([legacy_attrs])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    u = User.find(90001)
    assert_equal "u90001@example.com", u.email
    assert_equal "Niner", u.display_name
    assert_equal "100005840193753", u.external_provider_uid
    assert_equal true, u.legacy_migrated
    assert_equal "{\"id\":\"90001\",\"provider\":\"facebook\"}", u.legacy_v1_data
    assert_equal "google", u.external_provider  # raw int 2 -> :google
    assert_equal "user", u.role                 # raw int 0 -> :user
    assert_equal({"uid" => "fb-9"}, u.auth_data)
  end

  test "keeps a null email (presence validation bypassed)" do
    result = run_migrator([legacy_attrs("id" => 90002, "email" => nil)])
    assert result[:success], result[:error]
    assert_nil User.find(90002).email
  end

  test "inserts two accounts sharing an email (uniqueness bypassed)" do
    run_migrator([
      legacy_attrs("id" => 90003, "email" => "dup@example.com"),
      legacy_attrs("id" => 90004, "email" => "dup@example.com")
    ])
    assert_equal "dup@example.com", User.find(90003).email
    assert_equal "dup@example.com", User.find(90004).email
  end

  test "does not fire create_default_user_lists" do
    assert_no_difference -> { UserList.count } do
      run_migrator([legacy_attrs("id" => 90005)])
    end
  end

  test "preserves a nil external_provider" do
    run_migrator([legacy_attrs("id" => 90006, "external_provider" => nil)])
    assert_nil User.find(90006).external_provider
  end

  test "preserves legacy created_at and updated_at" do
    ca = Time.utc(2014, 7, 1, 2, 27, 33)
    ua = Time.utc(2019, 3, 15, 12, 0, 0)
    run_migrator([legacy_attrs("id" => 90007, "created_at" => ca, "updated_at" => ua)])
    u = User.find(90007)
    assert_equal ca, u.created_at
    assert_equal ua, u.updated_at
  end

  test "carries the migrated flag false and the v1 blob" do
    run_migrator([legacy_attrs("id" => 90008, "migrated" => false, "old_user_data" => "{\"x\":1}")])
    u = User.find(90008)
    assert_equal false, u.legacy_migrated
    assert_equal "{\"x\":1}", u.legacy_v1_data
  end

  test "is idempotent on id" do
    rows = [legacy_attrs("id" => 90009)]
    run_migrator(rows)
    assert_no_difference -> { User.count } do
      run_migrator(rows)
    end
  end

  test "provider_data JSON string round-trips through the serialize coder" do
    run_migrator([legacy_attrs("id" => 90010, "provider_data" => "{\"2\":{\"providerId\":\"google.com\"}}")])
    assert_equal({"2" => {"providerId" => "google.com"}}, User.find(90010).provider_data)
  end

  test "stores a blank provider_data as nil without crashing" do
    result = run_migrator([legacy_attrs("id" => 90011, "provider_data" => "")])
    assert result[:success], result[:error]
    assert_nil User.find(90011).provider_data
  end
end
