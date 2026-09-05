require "test_helper"
require "rake"
require "tmpdir"
require "json"

class FirebaseMigrationRakeTest < ActiveSupport::TestCase
  # Load only this one .rake file rather than Rails.application.load_tasks --
  # see penalties_rake_test.rb for why walking every railtie's hook produces
  # "already initialized constant" noise in an already-booted process.
  setup do
    unless Rake::Task.task_defined?("firebase:canary")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/firebase_migration.rake").to_s }
    end
    @dir = Dir.mktmpdir("fb-rake-test")
    %w[firebase:canary firebase:canary_for_user firebase:export_v1_passwords].each { |t| Rake::Task[t].reenable }
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # Both tasks print operator instructions on success and abort() to stderr on
  # failure. Swallow it: a clean `bin/rails test` is meant to stay clean, and
  # these tests assert on the file and the exit, never on the copy.
  def invoke(task, *args)
    capture_io { Rake::Task[task].invoke(*args) }
  end

  def invoke_expecting_exit(task, *args)
    status = nil
    capture_io { status = assert_raises(SystemExit) { Rake::Task[task].invoke(*args) } }
    status
  end

  test "the canary writes a record whose hash verifies against the password given" do
    require "bcrypt"
    path = File.join(@dir, "canary.json")

    invoke("firebase:canary", path, "Canary+V1@Example.com", "a-password-i-picked")

    record = JSON.parse(File.read(path))["users"].sole
    assert_equal "tgbv1-canary", record["localId"]
    assert_equal "canary+v1@example.com", record["email"], "the email must be normalised like the bulk export"
    assert_equal false, record["emailVerified"]

    # The point of the canary: the hash it ships must actually verify, or the
    # import proves nothing. Decoding it the way Firebase will and checking it
    # against the chosen plaintext is the whole assertion.
    decoded = Base64.urlsafe_decode64(record["passwordHash"])
    assert BCrypt::Password.new(decoded) == "a-password-i-picked",
      "the exported hash must verify against the plaintext the operator chose"
  end

  test "the canary hash matches the grammar the real cohort's hashes use" do
    path = File.join(@dir, "canary.json")

    invoke("firebase:canary", path, "canary@example.com", "pw")

    decoded = Base64.urlsafe_decode64(JSON.parse(File.read(path))["users"].sole["passwordHash"])
    assert_match Services::BooksMigration::FirebasePasswordExport::BCRYPT_GRAMMAR, decoded,
      "a canary that does not match the cohort grammar would prove nothing about the real hashes"
  end

  test "the canary writes readable only by its owner" do
    path = File.join(@dir, "canary.json")

    invoke("firebase:canary", path, "canary@example.com", "pw")

    assert_equal "100600", format("%o", File.stat(path).mode)
  end

  # File.open's mode applies only on creation, and these steps are re-run.
  test "the canary tightens permissions when overwriting an existing file" do
    path = File.join(@dir, "canary.json")
    File.write(path, "{}")
    File.chmod(0o644, path)

    invoke("firebase:canary", path, "canary@example.com", "pw")

    assert_equal "100600", format("%o", File.stat(path).mode)
  end

  # The plan let the canary write anywhere. It emits a real bcrypt hash, so it
  # gets the bulk export's refusal too.
  test "the canary refuses to write inside the repository" do
    path = Rails.root.join("tmp", "canary.json").to_s

    status = invoke_expecting_exit("firebase:canary", path, "canary@example.com", "pw")

    refute_equal 0, status.status
    refute File.exist?(path), "no hash may be written inside this public repository"
  end

  test "the export aborts rather than raising a backtrace on a repo path" do
    path = Rails.root.join("tmp", "users.json").to_s

    status = invoke_expecting_exit("firebase:export_v1_passwords", path)

    refute_equal 0, status.status
    refute File.exist?(path)
  end

  # canary_for_user rehearses the path the 30,387 real users actually take, which
  # the plain canary structurally cannot: localId = tgbv1-<a real users.id>, with
  # that same value pre-seeded on the row, so step 1 of find_user matches by uid
  # and the user lands on their existing data instead of a fresh empty account.
  test "canary_for_user derives the localId from the user id and uses their email" do
    user = User.create!(id: 940_001, email: "Rehearsal@Example.com")
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([])
    path = File.join(@dir, "canary-user.json")

    invoke("firebase:canary_for_user", path, user.id.to_s, "pw")

    record = JSON.parse(File.read(path))["users"].sole
    assert_equal "tgbv1-940001", record["localId"]
    assert_equal Services::BooksMigration::FirebasePasswordExport.uid_for(user.id), record["localId"]
    assert_equal "rehearsal@example.com", record["email"]
  end

  # Without this the rehearsal is meaningless: an unseeded row means the uid
  # lookup misses and sign-in takes the create path, which is what the plain
  # canary already did.
  test "canary_for_user seeds auth_uid on the row so the uid lookup can match" do
    user = User.create!(id: 940_002, email: "seed@example.com")
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([])

    invoke("firebase:canary_for_user", File.join(@dir, "c.json"), user.id.to_s, "pw")

    assert_equal "tgbv1-940002", user.reload.auth_uid
  end

  # Replace is total. Aiming this at a real cohort member would overwrite the
  # account they are about to be migrated into, with a password chosen here.
  test "canary_for_user refuses an id that is in the export cohort" do
    user = User.create!(id: 940_003, email: "cohort@example.com")
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([user.id])
    path = File.join(@dir, "c.json")

    invoke_expecting_exit("firebase:canary_for_user", path, user.id.to_s, "pw")

    refute File.exist?(path)
    assert_nil user.reload.auth_uid
  end

  # Overwriting a Firebase-native uid would detach that person from the account
  # they actually sign in with -- the same clobber the backfill guards against.
  test "canary_for_user refuses a user who already holds a different uid" do
    user = User.create!(id: 940_004, email: "native@example.com", auth_uid: "firebase-native-uid")
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([])

    invoke_expecting_exit("firebase:canary_for_user", File.join(@dir, "c.json"), user.id.to_s, "pw")

    assert_equal "firebase-native-uid", user.reload.auth_uid
  end

  test "canary_for_user is repeatable once the row already carries the derived uid" do
    user = User.create!(id: 940_005, email: "again@example.com", auth_uid: "tgbv1-940005")
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([])
    path = File.join(@dir, "c.json")

    invoke("firebase:canary_for_user", path, user.id.to_s, "pw")

    assert_equal "tgbv1-940005", JSON.parse(File.read(path))["users"].sole["localId"]
  end

  test "canary_for_user refuses an unknown user id" do
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([])
    path = File.join(@dir, "c.json")

    invoke_expecting_exit("firebase:canary_for_user", path, "99999999", "pw")

    refute File.exist?(path)
  end

  test "canary_for_user refuses to write inside the repository" do
    user = User.create!(id: 940_006, email: "repo@example.com")
    Services::BooksMigration::FirebasePasswordExport.stubs(:exportable_ids).returns([])
    path = Rails.root.join("tmp", "canary-user.json").to_s

    invoke_expecting_exit("firebase:canary_for_user", path, user.id.to_s, "pw")

    refute File.exist?(path)
    assert_nil user.reload.auth_uid, "nothing may be written before the path is checked"
  end

  test "both tasks refuse a blank path" do
    invoke_expecting_exit("firebase:export_v1_passwords", "")
    Rake::Task["firebase:canary"].reenable
    invoke_expecting_exit("firebase:canary", "", "a@b.com", "pw")
  end
end
