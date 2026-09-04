require "test_helper"
require "json"
require "tmpdir"

class Services::BooksMigration::FirebasePasswordExportTest < ActiveSupport::TestCase
  VALID_HASH = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy".freeze

  def setup
    @dir = Dir.mktmpdir("fb-export-test")
    @path = File.join(@dir, "users.json")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def legacy_attrs(overrides = {})
    {
      "id" => 90001,
      "email" => "u90001@example.com",
      "old_encrypted_password" => VALID_HASH,
      "last_sign_in_at" => nil,
      "created_at" => Time.utc(2015, 4, 28, 5, 28, 51)
    }.merge(overrides)
  end

  def run_export(rows, path: @path)
    exporter = Services::BooksMigration::FirebasePasswordExport.new(path)
    exporter.stubs(:legacy_each).multiple_yields(*rows.zip)
    exporter.call
  end

  def written(path = @path)
    JSON.parse(File.read(path))
  end

  test "writes one Firebase user record per cohort row" do
    result = run_export([legacy_attrs])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:exported]

    record = written["users"].sole
    assert_equal "tgbv1-90001", record["localId"]
    assert_equal "u90001@example.com", record["email"]
    assert_equal false, record["emailVerified"]
    # Epoch millis for the 2015-04-28 05:28:51 UTC fixture above. Firebase wants
    # milliseconds as a string. (The plan's literal here was 1430199731000,
    # which is 05:42:11 -- 800 seconds out.)
    assert_equal "1430198931000", record["createdAt"]
    assert record["passwordHash"].present?
  end

  test "the uid is derived from the legacy id and nothing else" do
    assert_equal "tgbv1-7", Services::BooksMigration::FirebasePasswordExport.uid_for(7)

    run_export([legacy_attrs("id" => 7)])
    assert_equal "tgbv1-7", written["users"].sole["localId"]
  end

  test "produces byte-identical output when run twice" do
    second = File.join(@dir, "second.json")
    rows = [legacy_attrs, legacy_attrs("id" => 90002, "email" => "u90002@example.com")]

    run_export(rows)
    run_export(rows, path: second)

    assert_equal File.read(@path), File.read(second)
  end

  test "the password hash round-trips back to the original bcrypt string" do
    run_export([legacy_attrs])

    encoded = written["users"].sole["passwordHash"]
    assert_equal VALID_HASH, Base64.urlsafe_decode64(encoded)
  end

  test "skips and counts a row whose hash is not bcrypt" do
    result = run_export([
      legacy_attrs,
      legacy_attrs("id" => 90002, "email" => "b@example.com", "old_encrypted_password" => "not-a-hash")
    ])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:exported]
    assert_equal 1, result[:data][:skipped][:invalid_hash]
    assert_equal 1, written["users"].length
  end

  # The 46 real rows shaped like "someone@gmail" with no TLD.
  test "skips and counts a malformed email rather than repairing it" do
    result = run_export([
      legacy_attrs,
      legacy_attrs("id" => 90003, "email" => "typo@gmail"),
      legacy_attrs("id" => 90004, "email" => "another@gmailcom")
    ])

    assert_equal 1, result[:data][:exported]
    assert_equal 2, result[:data][:skipped][:invalid_email]
    refute_includes written["users"].map { |u| u["email"] }, "typo@gmail"
  end

  test "keeps the most recently active row when two share an email" do
    result = run_export([
      legacy_attrs("id" => 90005, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2016, 1, 1)),
      legacy_attrs("id" => 90006, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2020, 1, 1))
    ])

    assert_equal 1, result[:data][:exported]
    assert_equal 1, result[:data][:skipped][:duplicate_email]
    assert_equal "tgbv1-90006", written["users"].sole["localId"]
  end

  # The winner must be chosen by last_sign_in_at, NOT by whichever row the
  # iteration happened to reach last. find_each forces ORDER BY id and discards
  # any scoped order, so a rule that depended on arrival order would silently
  # mean "highest legacy id wins" against the real database. Here the more
  # recently active row is also the LOWER id, and it is fed second, so an
  # arrival-order rule or an id rule both lose.
  test "picks the winner by last_sign_in_at regardless of arrival order" do
    result = run_export([
      legacy_attrs("id" => 90020, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2016, 1, 1)),
      legacy_attrs("id" => 90010, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2021, 6, 1))
    ])

    assert_equal 1, result[:data][:exported]
    assert_equal "tgbv1-90010", written["users"].sole["localId"]
  end

  # A row that never signed in must never displace one that did, whichever way round they arrive.
  test "a row that never signed in loses to one that did" do
    run_export([
      legacy_attrs("id" => 90011, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2018, 3, 1)),
      legacy_attrs("id" => 90012, "email" => "dupe@example.com", "last_sign_in_at" => nil)
    ])

    assert_equal "tgbv1-90011", written["users"].sole["localId"]
  end

  # Two rows that both never signed in still have to resolve the same way every
  # run, or the export stops being byte-identical across runs.
  test "breaks a tie on the legacy id when neither row ever signed in" do
    run_export([
      legacy_attrs("id" => 90014, "email" => "dupe@example.com", "last_sign_in_at" => nil),
      legacy_attrs("id" => 90013, "email" => "dupe@example.com", "last_sign_in_at" => nil)
    ])

    assert_equal "tgbv1-90014", written["users"].sole["localId"]
  end

  test "matches emails case-insensitively when deduping and downcases the output" do
    result = run_export([
      legacy_attrs("id" => 90007, "email" => "Mixed@Example.com"),
      legacy_attrs("id" => 90008, "email" => "mixed@example.com")
    ])

    assert_equal 1, result[:data][:exported]
    assert_equal "mixed@example.com", written["users"].sole["email"]
  end

  # The file is 30,463 password hashes and the repository is public.
  test "refuses to write inside the repository" do
    in_repo = Rails.root.join("tmp", "users.json").to_s

    assert_raises Services::BooksMigration::FirebasePasswordExport::UnsafeOutputPath do
      Services::BooksMigration::FirebasePasswordExport.new(in_repo).call
    end

    refute File.exist?(in_repo)
  end

  test "refuses to write inside the repository root above web-app" do
    in_repo = Rails.root.parent.join("users.json").to_s

    assert_raises Services::BooksMigration::FirebasePasswordExport::UnsafeOutputPath do
      Services::BooksMigration::FirebasePasswordExport.new(in_repo).call
    end
  end

  # 30 real cohort members already hold a Firebase-native uid, acquired by
  # signing in on the live music and games sites -- sign-in counts up to 120,
  # the most recent yesterday. Exporting them would create a SECOND Firebase
  # account per email carrying their 2014 password, because the import API does
  # not check email duplication. They already have a working identity; the
  # backfill skips them, and the export has to skip the same people or the two
  # halves disagree about who is being migrated.
  test "skips a cohort member whose users row already holds a Firebase uid" do
    linked = User.create!(id: 920_001, email: "linked@example.com", auth_uid: "firebase-native-uid")
    User.create!(id: 920_002, email: "unlinked@example.com")

    result = run_export([
      legacy_attrs("id" => linked.id, "email" => "linked@example.com"),
      legacy_attrs("id" => 920_002, "email" => "unlinked@example.com")
    ])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:exported]
    assert_equal 1, result[:data][:skipped][:already_linked]
    assert_equal ["tgbv1-920002"], written["users"].map { |u| u["localId"] }
  end

  # A cohort member with no users row at all must still export. The backfill is
  # what refuses in that case, loudly; the export must not quietly drop them.
  test "still exports a cohort member that has no users row yet" do
    result = run_export([legacy_attrs("id" => 920_003, "email" => "norow@example.com")])

    assert_equal 1, result[:data][:exported]
    assert_equal 0, result[:data][:skipped][:already_linked]
  end

  # The canary task writes a bcrypt hash too, and must not get its own,
  # divergent copy of this rule.
  test "exposes the repository guard as a reusable class method" do
    assert_raises Services::BooksMigration::FirebasePasswordExport::UnsafeOutputPath do
      Services::BooksMigration::FirebasePasswordExport.assert_safe_output_path!(
        Rails.root.join("tmp", "canary.json").to_s
      )
    end

    assert_nil Services::BooksMigration::FirebasePasswordExport.assert_safe_output_path!(
      File.join(@dir, "canary.json")
    )
  end

  test "writes the file readable only by its owner" do
    run_export([legacy_attrs])

    assert_equal "100600", format("%o", File.stat(@path).mode)
  end
end
