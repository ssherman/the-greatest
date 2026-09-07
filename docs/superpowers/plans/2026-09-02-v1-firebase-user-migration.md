# V1 Firebase User Migration Implementation Plan (PR 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give 30,463 v1 Devise users their existing passwords back by importing their bcrypt hashes into Firebase under deterministic uids, and wire the frontend so a user on any domain can recover.

**Architecture:** A rake-invoked service exports the cohort from the legacy database as a Firebase import file, assigning each user the deterministic uid `tgbv1-<legacy_id>`. The owner runs `firebase-tools auth:import` locally, so no service-account credential ever enters the app. A second service backfills the same derived uid into `users.auth_uid`, which lets PR 1's uid-primary lookup match these users on their first sign-in without any email involved.

**Tech Stack:** Rails 8.1, `LegacyBooks::User` (second database), `firebase-tools` via npx, Minitest + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-02-email-password-auth-design.md`

**Depends on:** `docs/superpowers/plans/2026-09-02-auth-hardening.md` must be merged first. This plan assumes `UserAuthenticationService` is uid-primary and `AuthenticationService` returns `error_code`.

## Global Constraints

- Run all commands from `web-app/`. Docs live at the project root, not `web-app/docs/`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`).
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`.
- **The development database is not disposable.** The books data exists only in dev and takes hours to rebuild. Snapshot before the backfill: `bin/snapshot-dev-db.sh --label pre-firebase-uid-backfill` (prefix with `COMPOSE_PROJECT_NAME=the-greatest` from a worktree).
- A `PreToolUse` hook blocks bulk `update_all` inside `rails runner`. The backfill runs as a **rake task**, which is not blocked. Do not port it to `rails runner`.
- **The export file contains 30,463 password hashes and this repository is public.** It must never be written inside the repo and never committed.
- Deterministic uid format, used identically in both services: `"tgbv1-#{legacy_id}"`.
- Cohort definition, identical in both services: `LegacyBooks::User` where `migrated` IN (false, NULL) AND `external_provider` IS NULL AND `old_encrypted_password` is present AND `email` is present. Measured size: 30,463.
- Never commit to `main`. This work is on `worktree-email-password-auth`.

## Measured facts this plan relies on

Verified against the development database on 2026-09-02:

| Fact | Value |
|---|---|
| Cohort size | 30,463 |
| Hashes matching `^\$2a\$10\$[./A-Za-z0-9]{53}$` | 30,463 of 30,463 |
| Distinct salts | 30,463 |
| Duplicate emails **within** the cohort | **0** |
| Cohort emails also held by a row outside the cohort | **0** |
| Emails with whitespace or uppercase | 0 |
| Emails failing a basic shape check | **46** (32 of them hold list data) |
| Rows with a NULL `created_at` | 0 |

The 46 malformed addresses are signup typos — `@gmail` with no TLD, `@gmailcom`,
`@123`, `@1998`. They were never deliverable. They are **skipped and reported**,
never repaired: inferring `gmail.com` from `gmail` would create a Firebase
account at an address the user does not control, which is precisely the
takeover shape this project exists to remove.

The zero duplicates and zero collisions mean the dedup logic below will not fire
today. It stays in as an assertion — if a future run reports a non-zero count,
the data changed and the run should be examined rather than trusted.

## Re-running all of this, repeatedly

The owner's working pattern is to truncate everything and re-run the full data
migration, more than once, before books launches. **All three steps here are
designed to survive that, and the property doing the work is that the uid is
derived rather than stored.**

`UserMigrator` upserts `unique_by: :id` with ids taken from the static legacy
database, so re-migrating reproduces identical `users.id` values, so
`tgbv1-<id>` derives to the same string every time.

Firebase's import API then behaves as follows
([docs](https://firebase.google.com/docs/auth/admin/import-users)):

> The user import API is optimized for speed and does not check for uid, email,
> phoneNumber and other unique identifier duplication. Importing a user that
> collides with an existing uid will replace the existing user. However,
> importing a user with any other field duplicated (e.g. email) will result in
> an additional user with the same value.

So a re-import replaces each account in place: no duplicates, no errors, no
cleanup step. The write-back is independently idempotent — it recomputes rather
than reading the export file, and scopes to `auth_uid IS NULL`.

**Two consequences of "replace" that are not obvious:**

1. **Replace is total, so the import has a shelf life.** Re-importing overwrites
   whatever the account has become — a password the user changed, an email they
   verified — back to the 2014 bcrypt hash and `emailVerified: false`. **Once
   books is live and real people have used these accounts, the import must not
   be re-run.** The export and the write-back stay safe to re-run; only the
   Firebase import carries this.

   **The bulk import IS re-run against production on every rehearsal, and that
   is deliberate.** The whole point of deriving the uid from the legacy id is
   that the import is idempotent, and an idempotent step is worthless unless it
   is actually exercised — a 30,437-row import performed for the first time at
   launch is the larger risk by far. Prove it with the canary (Task 2), then
   re-run the real thing as often as the data migration is re-run.

   **What "books is not live yet" does NOT buy you.** It does not make the
   cohort unreachable. `firebase_auth_service.js` hardcodes
   `projectId: "the-greatest-books"` and varies only `authDomain`, so every
   domain authenticates against one Firebase project, and
   `Authentication::WidgetComponent` renders in all four layouts — including
   the **live** music and games sites. So from the first production import
   onward, any of these 30,437 people can sign in, or trigger a
   forgot-password email, on thegreatest.music or thegreatest.games. The
   import is what creates that reachability; books launch has nothing to do
   with it.

   **The owner weighed this and accepted it (2026-09-03.)** The residual risk
   is that someone in the cohort signs in on music or games during the
   pre-launch window, changes their password, and has it silently reverted by
   the next rehearsal import. Accepted because the cohort has zero sign-ins in
   two years and the window is short, against the much larger risk of an
   unrehearsed import at launch. **Do not re-raise this as a defect and do not
   quietly reintroduce an "import only once" rule** — it was raised in review
   on PR #289, considered, and declined. The obligation the decision creates is
   that the import must be *proven* idempotent, not that it be avoided.

   Within each cycle, run the import before the write-back (the order in
   "Running it" below), so `auth_uid` never points at an identity that does not
   exist yet.

2. **If id stability ever breaks, the failure is silent.** Because the API does
   not check email duplication, a re-migration that assigned *different* ids
   would not error — it would create a second Firebase account per user sharing
   the same email. The console's "one account per email address" setting does not
   protect against this; it governs the client SDK's signup path, not the admin
   import API. The only guard is that `UserMigrator` keeps preserving legacy ids.
   If that ever changes, this breaks quietly and at scale.

Task 2's canary should therefore be run **twice** against the same record, to
confirm the replace path behaves as documented before 30,463 records depend on it.

---

### Task 1: Export the cohort as a Firebase import file

**Files:**
- Create: `app/lib/services/books_migration/firebase_password_export.rb`
- Create: `test/lib/services/books_migration/firebase_password_export_test.rb`

**Interfaces:**
- Consumes: `LegacyBooks::User`.
- Produces:
  - `Services::BooksMigration::FirebasePasswordExport.call(output_path:)` → `{success: true, data: {path:, exported:, skipped: {invalid_email:, invalid_hash:, duplicate_email:}}}` or `{success: false, error:, data: {...}}`
  - `Services::BooksMigration::FirebasePasswordExport.uid_for(legacy_id)` → `"tgbv1-<id>"` — Task 3 calls this so the two services cannot drift.
  - Constants `BCRYPT_GRAMMAR`, `EMAIL_GRAMMAR`, `UID_PREFIX`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/books_migration/firebase_password_export_test.rb`:

```ruby
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
    assert_equal "1430199731000", record["createdAt"]
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

  test "keeps only the most recently seen row when two share an email" do
    result = run_export([
      legacy_attrs("id" => 90005, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2016, 1, 1)),
      legacy_attrs("id" => 90006, "email" => "dupe@example.com", "last_sign_in_at" => Time.utc(2020, 1, 1))
    ])

    assert_equal 1, result[:data][:exported]
    assert_equal 1, result[:data][:skipped][:duplicate_email]
    assert_equal "tgbv1-90006", written["users"].sole["localId"]
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

  test "writes the file readable only by its owner" do
    run_export([legacy_attrs])

    assert_equal "100600", format("%o", File.stat(@path).mode)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/firebase_password_export_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::FirebasePasswordExport`.

- [ ] **Step 3: Write the service**

Create `app/lib/services/books_migration/firebase_password_export.rb`:

```ruby
require "json"
require "base64"

module Services
  module BooksMigration
    # Exports the v1 Devise cohort as a Firebase Auth bulk-import file, so those
    # users sign in with the password they already have.
    #
    # This replaces the legacy site's bespoke "decrypt the old password, compare
    # it, then create a Firebase account" endpoint, which could be driven by
    # anyone who knew an email address. Importing the hashes means there is no
    # such endpoint to attack: Firebase verifies the password itself, through
    # the ordinary sign-in path.
    #
    # Run it, then:
    #   npx firebase-tools auth:import <path> --hash-algo=BCRYPT --project the-greatest-books
    #
    # Nothing here touches Firebase. No service-account credential belongs in
    # this application for a one-time job.
    class FirebasePasswordExport
      # Every one of the 30,463 real hashes matches this exactly. Anything that
      # does not is skipped rather than shipped -- Firebase would reject the row
      # anyway, and a malformed hash would occupy an address its owner could
      # then never claim.
      BCRYPT_GRAMMAR = %r{\A\$2a\$10\$[./A-Za-z0-9]{53}\z}

      # Deliberately loose: this only rejects addresses Firebase itself will
      # reject. 46 real rows look like "someone@gmail" with no TLD -- signup
      # typos that were never deliverable. They are skipped, NEVER repaired:
      # inferring "gmail.com" from "gmail" would create an account at an address
      # the user does not control.
      EMAIL_GRAMMAR = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      UID_PREFIX = "tgbv1-"
      BATCH_SIZE = 1000

      class UnsafeOutputPath < StandardError; end

      # The single definition of the uid. FirebaseUidBackfill calls this rather
      # than rebuilding the string, so the exported localId and the value written
      # to users.auth_uid cannot drift apart.
      def self.uid_for(legacy_id)
        "#{UID_PREFIX}#{legacy_id}"
      end

      def self.call(output_path:)
        new(output_path).call
      end

      def initialize(output_path)
        @output_path = output_path
        @skipped = {invalid_email: 0, invalid_hash: 0, duplicate_email: 0}
      end

      def call
        assert_safe_output_path!

        by_email = {}
        legacy_each do |attrs|
          record = build_record(attrs)
          next if record.nil?

          key = record.fetch("email")
          # Zero duplicates exist today. Kept as an assertion: last row wins,
          # and the collision is counted so a non-zero report is investigated
          # rather than silently accepted.
          @skipped[:duplicate_email] += 1 if by_email.key?(key)
          by_email[key] = record
        end

        write(by_email.values)

        {success: true, data: {path: @output_path, exported: by_email.size, skipped: @skipped}}
      rescue UnsafeOutputPath
        raise
      rescue => e
        {success: false, error: e.message, data: {path: @output_path, exported: 0, skipped: @skipped}}
      end

      private

      def build_record(attrs)
        email = attrs["email"].to_s.strip.downcase
        hash = attrs["old_encrypted_password"].to_s

        unless EMAIL_GRAMMAR.match?(email)
          @skipped[:invalid_email] += 1
          return nil
        end

        unless BCRYPT_GRAMMAR.match?(hash)
          @skipped[:invalid_hash] += 1
          return nil
        end

        {
          "localId" => self.class.uid_for(attrs["id"]),
          "email" => email,
          # Honest: these addresses were never confirmed. It costs nothing --
          # PR 1 links these users by uid, not by email, so verification status
          # is irrelevant to them reaching their own account.
          "emailVerified" => false,
          "passwordHash" => encode_hash(hash),
          "createdAt" => (attrs["created_at"].to_time.to_i * 1000).to_s
        }
      end

      # Firebase's import format carries passwordHash base64url-encoded without
      # padding. CONFIRMED BY THE CANARY IMPORT, not by documentation -- if a
      # single-record canary fails to authenticate, this method is the one place
      # to change (plain Base64.strict_encode64, or the raw string).
      def encode_hash(hash)
        Base64.urlsafe_encode64(hash, padding: false)
      end

      def write(records)
        File.open(@output_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(JSON.pretty_generate({"users" => records}))
        end
      end

      # The file is tens of thousands of password hashes and this repository is
      # public. Refusing the whole repo tree is cheaper than trusting a
      # .gitignore entry to be correct forever.
      def assert_safe_output_path!
        expanded = File.expand_path(@output_path)
        repo_root = Rails.root.parent.to_s

        if expanded.start_with?(repo_root + File::SEPARATOR)
          raise UnsafeOutputPath,
            "refusing to write password hashes inside the repository (#{repo_root}). " \
            "Choose a path outside it."
        end
      end

      def cohort
        LegacyBooks::User
          .where(migrated: [false, nil])
          .where(external_provider: nil)
          .where("old_encrypted_password IS NOT NULL AND old_encrypted_password <> ''")
          .where("email IS NOT NULL AND email <> ''")
          .order(:last_sign_in_at, :id)
      end

      # Ordered so that on a duplicate email the most recently active row is
      # seen last and wins. Stubbed in tests so the legacy connection never opens.
      def legacy_each(&block)
        cohort.find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/firebase_password_export_test.rb`
Expected: 11 runs, 0 failures.

Note: `find_each` ignores `order`, so if the duplicate-ordering guarantee ever
matters against the real database, the test above still pins the last-wins
behaviour at the record level. With 0 duplicates today this is inert.

- [ ] **Step 5: Prove the safety guard is not vacuous (mutation evidence)**

Comment out the `assert_safe_output_path!` call in `call`. Re-run. Both
"refuses to write inside the repository" tests MUST fail. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/firebase_password_export.rb test/lib/services/books_migration/firebase_password_export_test.rb
git add app/lib/services/books_migration/firebase_password_export.rb test/lib/services/books_migration/firebase_password_export_test.rb
git commit -m "feat: export v1 Devise bcrypt hashes as a Firebase import file

Deterministic tgbv1-<legacy_id> uids, 0600 output, and a hard refusal to write
anywhere inside this public repository."
```

---

### Task 2: Rake tasks for the export and the canary

**Files:**
- Create: `lib/tasks/firebase_migration.rake`
- Modify: `.gitignore` (repository root, one line)

**Interfaces:**
- Consumes: `Services::BooksMigration::FirebasePasswordExport`.
- Produces: `rake firebase:export_v1_passwords[path]` and `rake firebase:canary[path,email,password]`.

- [ ] **Step 1: Write the rake tasks**

Create `lib/tasks/firebase_migration.rake`:

```ruby
namespace :firebase do
  desc "Export the v1 Devise cohort as a Firebase auth:import file. Usage: rake 'firebase:export_v1_passwords[/abs/path/users.json]'"
  task :export_v1_passwords, [:path] => :environment do |_t, args|
    path = args[:path]
    abort "Usage: rake 'firebase:export_v1_passwords[/abs/path/users.json]'" if path.blank?

    result = Services::BooksMigration::FirebasePasswordExport.call(output_path: path)
    pp result

    if result[:success]
      puts
      puts "Next, from anywhere OUTSIDE this repository:"
      puts "  npx firebase-tools auth:import #{path} --hash-algo=BCRYPT --project the-greatest-books"
      puts
      puts "Then, once sign-in is confirmed:"
      puts "  rake firebase:backfill_v1_uids"
    else
      abort "Export failed: #{result[:error]}"
    end
  end

  desc "Write a single-record canary import file with a password you choose. Usage: rake 'firebase:canary[/abs/path/canary.json,you+v1@gmail.com,somepassword]'"
  task :canary, [:path, :email, :password] => :environment do |_t, args|
    require "bcrypt"
    path, email, password = args[:path], args[:email], args[:password]
    abort "Usage: rake 'firebase:canary[/abs/path/canary.json,email,password]'" if [path, email, password].any?(&:blank?)

    # Cost 10 and the $2a$ variant: byte-for-byte the same construction Devise
    # used in 2014. A hash's age changes nothing about how bcrypt verifies it,
    # which is why this proves the import path for all 30,463 real hashes.
    hash = BCrypt::Password.create(password, cost: 10).to_s
    unless Services::BooksMigration::FirebasePasswordExport::BCRYPT_GRAMMAR.match?(hash)
      abort "Generated hash does not match the cohort grammar: #{hash[0, 7]}..."
    end

    record = {
      "localId" => "tgbv1-canary",
      "email" => email.strip.downcase,
      "emailVerified" => false,
      "passwordHash" => Base64.urlsafe_encode64(hash, padding: false),
      "createdAt" => (Time.current.to_i * 1000).to_s
    }

    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate({"users" => [record]}))
    end

    puts "Wrote #{path}"
    puts "  npx firebase-tools auth:import #{path} --hash-algo=BCRYPT --project the-greatest-books"
    puts "Then sign in at https://dev-new.thegreatestbooks.org with #{email} and the password you passed."
    puts "If that fails, FirebasePasswordExport#encode_hash is the one thing to change."
  end
end
```

- [ ] **Step 2: Add the bcrypt gem for the canary task only**

The app has no `bcrypt` gem — it never handles passwords. The canary task
needs it to *generate* a test hash. Add to `web-app/Gemfile` in the
`group :development, :test` block:

```ruby
  # Only for firebase:canary, which generates a known-plaintext hash matching
  # the v1 cohort's construction. The app itself never hashes a password.
  gem "bcrypt", "~> 3.1"
```

Then:

```bash
bundle install
```

- [ ] **Step 3: Add the gitignore entry**

Append to the **repository root** `.gitignore` (not `web-app/.gitignore`):

```
# Firebase auth import files: tens of thousands of bcrypt password hashes.
# FirebasePasswordExport also refuses to write anywhere in this tree; this is
# the second line of defence, not the first.
*firebase-import*.json
*auth-import*.json
```

- [ ] **Step 4: Verify the tasks load and the guard holds**

```bash
bin/rails -T firebase
```
Expected: both tasks listed.

```bash
bin/rails "firebase:export_v1_passwords[tmp/should-refuse.json]"
```
Expected: aborts with the `UnsafeOutputPath` message. Confirm no file was created.

- [ ] **Step 5: Commit**

```bash
bundle exec standardrb --fix lib/tasks/firebase_migration.rake
git add lib/tasks/firebase_migration.rake Gemfile Gemfile.lock ../.gitignore
git commit -m "feat: rake tasks for the v1 password export and the import canary"
```

---

### Task 3: Backfill the derived uid onto users.auth_uid

**Files:**
- Create: `app/lib/services/books_migration/firebase_uid_backfill.rb`
- Create: `test/lib/services/books_migration/firebase_uid_backfill_test.rb`

**Interfaces:**
- Consumes: `Services::BooksMigration::FirebasePasswordExport.uid_for(legacy_id)` (Task 1).
- Produces: `Services::BooksMigration::FirebaseUidBackfill.call(dry_run: false)` → `{success: true, data: {eligible:, updated:, already_set:, missing_target: []}}` or `{success: false, error:, data: {...}}`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/books_migration/firebase_uid_backfill_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::FirebaseUidBackfillTest < ActiveSupport::TestCase
  def run_backfill(ids, dry_run: false)
    backfill = Services::BooksMigration::FirebaseUidBackfill.new(dry_run: dry_run)
    backfill.stubs(:cohort_ids).returns(ids)
    backfill.call
  end

  def make_user(id, attrs = {})
    User.create!({id: id, email: "u#{id}@example.com"}.merge(attrs))
  end

  test "writes the derived uid onto every eligible user" do
    make_user(910001)
    make_user(910002)

    result = run_backfill([910001, 910002])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:updated]
    assert_equal "tgbv1-910001", User.find(910001).auth_uid
    assert_equal "tgbv1-910002", User.find(910002).auth_uid
  end

  test "derives the same uid the exporter does" do
    make_user(910003)
    run_backfill([910003])

    assert_equal Services::BooksMigration::FirebasePasswordExport.uid_for(910003),
      User.find(910003).auth_uid
  end

  test "never overwrites an auth_uid that is already set" do
    make_user(910004, auth_uid: "firebase-native-uid")

    result = run_backfill([910004])

    assert_equal 0, result[:data][:updated]
    assert_equal 1, result[:data][:already_set]
    assert_equal "firebase-native-uid", User.find(910004).auth_uid
  end

  test "is idempotent -- a second run updates nothing" do
    make_user(910005)

    run_backfill([910005])
    second = run_backfill([910005])

    assert_equal 0, second[:data][:updated]
    assert_equal "tgbv1-910005", User.find(910005).auth_uid
  end

  # The id-preservation invariant. UserMigrator upserts unique_by: :id, so a
  # cohort id with no matching new-table row means the user migration did not
  # run or did not run fully. Backfilling around that would silently leave
  # those users unable to sign in.
  test "fails hard when a cohort id has no row in the new users table" do
    make_user(910006)

    result = run_backfill([910006, 99999999])

    refute result[:success]
    assert_includes result[:error], "99999999"
    assert_equal [99999999], result[:data][:missing_target]
  end

  test "a failed run writes nothing at all" do
    make_user(910007)

    run_backfill([910007, 99999999])

    assert_nil User.find(910007).auth_uid
  end

  test "dry_run reports what it would do and changes nothing" do
    make_user(910008)

    result = run_backfill([910008], dry_run: true)

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:eligible]
    assert_equal 0, result[:data][:updated]
    assert_nil User.find(910008).auth_uid
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/firebase_uid_backfill_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::FirebaseUidBackfill`.

- [ ] **Step 3: Write the service**

Create `app/lib/services/books_migration/firebase_uid_backfill.rb`:

```ruby
module Services
  module BooksMigration
    # Writes the imported Firebase uid onto users.auth_uid so PR 1's uid-primary
    # lookup matches a v1 user on their first sign-in without any email being
    # involved.
    #
    # It recomputes the uid rather than reading the export file: the value is
    # derived from the id, so the two cannot drift, this is safe to run in any
    # environment, and it needs nothing shipped between machines.
    #
    # This is only correct because UserMigrator upserts unique_by: :id, making
    # LegacyBooks::User#id and User#id the same integer for the same person. A
    # cohort id with no new-table row means that migration did not fully run, so
    # the whole backfill aborts rather than skipping the row -- a skipped row is
    # a user who silently cannot sign in.
    class FirebaseUidBackfill
      BATCH_SIZE = 1000

      def self.call(dry_run: false)
        new(dry_run: dry_run).call
      end

      def initialize(dry_run: false)
        @dry_run = dry_run
      end

      def call
        ids = cohort_ids
        return empty_result if ids.empty?

        present_ids = User.where(id: ids).pluck(:id)
        missing = ids - present_ids
        if missing.any?
          return {
            success: false,
            error: "#{missing.size} cohort ids have no row in users (first: #{missing.first(5).join(", ")}). " \
                   "Run data_migration:users first.",
            data: {eligible: 0, updated: 0, already_set: 0, missing_target: missing}
          }
        end

        eligible = User.where(id: ids, auth_uid: nil).pluck(:id)
        already_set = ids.size - eligible.size

        return dry_result(eligible.size, already_set) if @dry_run

        updated = 0
        eligible.each_slice(BATCH_SIZE) do |slice|
          updated += update_slice(slice)
        end

        {success: true, data: {eligible: eligible.size, updated: updated, already_set: already_set, missing_target: []}}
      rescue => e
        {success: false, error: e.message, data: {eligible: 0, updated: 0, already_set: 0, missing_target: []}}
      end

      private

      # One statement per batch, deriving the uid in SQL so 30k rows do not become
      # 30k UPDATEs. Scoped to auth_uid IS NULL so a Firebase-native uid on an
      # account is never clobbered.
      def update_slice(ids)
        User.where(id: ids, auth_uid: nil).update_all([
          "auth_uid = ? || id::text, updated_at = ?",
          Services::BooksMigration::FirebasePasswordExport::UID_PREFIX,
          Time.current
        ])
      end

      def cohort_ids
        LegacyBooks::User
          .where(migrated: [false, nil])
          .where(external_provider: nil)
          .where("old_encrypted_password IS NOT NULL AND old_encrypted_password <> ''")
          .where("email IS NOT NULL AND email <> ''")
          .pluck(:id)
      end

      def empty_result
        {success: true, data: {eligible: 0, updated: 0, already_set: 0, missing_target: []}}
      end

      def dry_result(eligible, already_set)
        {success: true, data: {eligible: eligible, updated: 0, already_set: already_set, missing_target: []}}
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/firebase_uid_backfill_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 5: Prove the missing-row guard is not vacuous (mutation evidence)**

Replace the `if missing.any?` block's early return with `nil` so it falls
through. Re-run. Both "fails hard when a cohort id has no row" and "a failed
run writes nothing at all" MUST fail. Restore.

- [ ] **Step 6: Add the rake task**

Append to `lib/tasks/firebase_migration.rake`, inside the `namespace :firebase`
block:

```ruby
  desc "Write tgbv1-<id> into users.auth_uid for the v1 cohort. Pass DRY_RUN=1 to preview."
  task backfill_v1_uids: :environment do
    dry = ENV["DRY_RUN"].present?
    puts dry ? "DRY RUN -- nothing will be written" : "Writing auth_uid for the v1 cohort..."

    result = Services::BooksMigration::FirebaseUidBackfill.call(dry_run: dry)
    pp result

    abort "Backfill failed: #{result[:error]}" unless result[:success]
  end
```

- [ ] **Step 7: Verify against the real cohort with a dry run**

First snapshot the development database — it is not disposable:

```bash
COMPOSE_PROJECT_NAME=the-greatest bin/snapshot-dev-db.sh --label pre-firebase-uid-backfill
```

Then:

```bash
DRY_RUN=1 bin/rails firebase:backfill_v1_uids
```

Expected: `success: true`, `eligible: 30463`, `updated: 0`, `missing_target: []`.
If `missing_target` is non-empty, stop — the user migration is incomplete and
the export is not safe to import either.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/firebase_uid_backfill.rb test/lib/services/books_migration/firebase_uid_backfill_test.rb lib/tasks/firebase_migration.rake
git add app/lib/services/books_migration/firebase_uid_backfill.rb test/lib/services/books_migration/firebase_uid_backfill_test.rb lib/tasks/firebase_migration.rake
git commit -m "feat: backfill derived Firebase uids onto users.auth_uid

Recomputes rather than reading the export, so it is idempotent and
environment-independent. Aborts when a cohort id has no new-table row --
the id-preservation invariant the derived uid depends on."
```

---

### Task 4: Send password-reset and verification links to the domain the user is on

**Files:**
- Modify: `app/javascript/services/auth_providers/email_provider.js`
- Create: `test/lint/firebase_action_code_settings_test.rb`

**Interfaces:**
- Consumes: `window.location.origin`.
- Produces: `emailProvider.actionCodeSettings()` → `{url, handleCodeInApp: false}`.

- [ ] **Step 1: Write the failing lint test**

There is no JS test runner in this project, so this is a source-level guard in
the same spirit as `test/lint/daisyui_v4_classes_test.rb`. Create
`test/lint/firebase_action_code_settings_test.rb`:

```ruby
require "test_helper"

# sendPasswordResetEmail and sendEmailVerification without actionCodeSettings
# fall back to Firebase's project-wide default action URL -- a books URL. A
# reader who resets their password on games would be emailed a link that lands
# on books.
class FirebaseActionCodeSettingsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/services/auth_providers/email_provider.js")

  test "every action-code email call passes actionCodeSettings" do
    source = File.read(SOURCE)

    %w[sendPasswordResetEmail sendEmailVerification].each do |fn|
      calls = source.scan(/#{fn}\(([^)]*)\)/m).flatten
      invocations = calls.reject { |args| args.strip.empty? }

      assert invocations.any?, "expected at least one #{fn} call in #{SOURCE}"

      invocations.each do |args|
        assert_includes args, "actionCodeSettings",
          "#{fn}(#{args.strip}) omits actionCodeSettings, so its email would " \
          "link to the Firebase project default domain instead of the caller's"
      end
    end
  end

  test "the settings are derived from the live origin, not a hardcoded host" do
    source = File.read(SOURCE)

    assert_includes source, "window.location.origin"
    refute_match(/url:\s*['"]https:\/\/[a-z]/, source,
      "actionCodeSettings.url must be derived from the current origin")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lint/firebase_action_code_settings_test.rb`
Expected: FAIL — both `sendPasswordResetEmail(auth, email)` and
`sendEmailVerification(result.user)` currently pass no settings.

- [ ] **Step 3: Update the provider**

In `app/javascript/services/auth_providers/email_provider.js`, add this method
to the `EmailProvider` class, above `signUp`:

```javascript
  // Firebase's reset and verification emails link to the project's single
  // default action URL unless told otherwise -- so a games reader resetting a
  // password would be emailed a books link. Deriving from the live origin sends
  // them back to the site they were actually on.
  //
  // Every domain used here must be on Firebase's authorized-domains list, or
  // the SDK rejects the call with auth/unauthorized-continue-uri.
  actionCodeSettings() {
    return {
      url: `${window.location.origin}/`,
      handleCodeInApp: false
    }
  }
```

Then change the two call sites:

```javascript
      await sendEmailVerification(result.user, this.actionCodeSettings())
```

```javascript
      await sendPasswordResetEmail(auth, email, this.actionCodeSettings())
```

and in `resendVerification`:

```javascript
        await sendEmailVerification(user, this.actionCodeSettings())
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lint/firebase_action_code_settings_test.rb`
Expected: 2 runs, 0 failures.

- [ ] **Step 5: Rebuild and commit**

```bash
yarn build:all
bundle exec standardrb --fix test/lint/firebase_action_code_settings_test.rb
git add app/javascript/services/auth_providers/email_provider.js test/lint/firebase_action_code_settings_test.rb
git commit -m "fix: send Firebase action emails back to the caller's domain"
```

---

### Task 5: Point stranded users at the door that works

**Files:**
- Modify: `app/javascript/controllers/authentication_controller.js` (the `checkProviderConflict` method)

**Interfaces:**
- Consumes: the existing `/auth/check_provider` response.
- Produces: no API change.

- [ ] **Step 1: Change the failed-sign-in copy**

After the import, 37 accounts still hold an email with no Firebase identity,
plus the 46 whose addresses were never valid. For them `sendPasswordResetEmail`
fails `auth/user-not-found` and the UI's deliberately vague "if an account
exists..." message hides it. Their working route is **Create account**, which
sets a password, sends a verification email, and then links to their existing
row through PR 1's step 2.

Adding an endpoint that confirms "this address has an account" would be a clean
enumeration oracle against a public repository. This message is shown
identically to everyone and leaks nothing.

In `app/javascript/controllers/authentication_controller.js`, in
`checkProviderConflict`, replace **both** occurrences of

```javascript
        this.showError('Invalid email or password.')
```

with

```javascript
        this.showError(
          "Invalid email or password. If you had an account on the old site and haven't " +
          "set a password here yet, choose Create account with this address."
        )
```

(There are two: the `else` branch and the `catch` branch. Both must change, so
a network failure on the provider check shows the same guidance.)

- [ ] **Step 2: Rebuild and verify by hand**

```bash
yarn build:all
```

Check port ownership before starting a server:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If free, `bin/rails server`, then on `dev-new.thegreatestbooks.org` enter an
address that has no account, any password, and confirm the new message appears.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/authentication_controller.js
git commit -m "fix: point users with no password set at Create account"
```

---

### Task 6: E2E coverage for the email/password flow

**Files:**
- Create: `e2e/tests/books/email-auth.spec.ts`

**Interfaces:**
- Consumes: `PLAYWRIGHT_ADMIN_EMAIL` / `PLAYWRIGHT_ADMIN_PASSWORD` from `e2e/.env`.

- [ ] **Step 1: Write the spec**

Sign-in and the error paths only. Not sign-up: a real signup creates a live
Firebase account in the shared project on every run.

Create `e2e/tests/books/email-auth.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.use({ baseURL: 'https://dev-new.thegreatestbooks.org', storageState: { cookies: [], origins: [] } });

test.describe('email/password authentication', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page.locator('#login_modal')).toBeVisible();
  });

  test('signs in with a valid email and password', async ({ page }) => {
    const modal = page.locator('#login_modal');

    await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
    await modal.getByRole('button', { name: 'Continue' }).click();

    const password = modal.getByPlaceholder('Password');
    await expect(password).toBeVisible();
    await password.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
    await modal.getByRole('button', { name: 'Sign In' }).click();

    await expect(page.getByRole('button', { name: 'Logout' })).toBeVisible({ timeout: 15000 });
  });

  test('shows the create-account guidance on a wrong password', async ({ page }) => {
    const modal = page.locator('#login_modal');

    await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
    await modal.getByRole('button', { name: 'Continue' }).click();
    await modal.getByPlaceholder('Password').fill('definitely-not-the-password');
    await modal.getByRole('button', { name: 'Sign In' }).click();

    await expect(modal.getByText(/Invalid email or password/)).toBeVisible({ timeout: 15000 });
    await expect(modal.getByText(/choose Create account with this address/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Logout' })).toHaveCount(0);
  });

  test('the forgot-password form does not reveal whether an account exists', async ({ page }) => {
    const modal = page.locator('#login_modal');

    await modal.getByPlaceholder('Email address').first().fill('nobody-has-this-address@example.com');
    await modal.getByRole('button', { name: 'Continue' }).click();
    await modal.getByRole('link', { name: 'Forgot password?' }).click();
    await modal.getByRole('button', { name: 'Send Reset Link' }).click();

    await expect(modal.getByText(/If an account exists with this email/)).toBeVisible({ timeout: 15000 });
  });
});
```

- [ ] **Step 2: Confirm port 3000 is yours, then run it**

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If another checkout holds it, **stop and report it** — Caddy proxies every dev
hostname to whatever is on :3000, so the run would silently test that
checkout's code and report the result as yours. Do not kill their server and do
not use another port (routes are host-constrained).

```bash
yarn build:all
bin/rails server
# in another shell:
yarn test:e2e e2e/tests/books/email-auth.spec.ts
```

Expected: 3 passed.

- [ ] **Step 3: Commit**

```bash
git add e2e/tests/books/email-auth.spec.ts
git commit -m "test: E2E coverage for email/password sign-in and its error paths"
```

---

### Task 7: Record the migration and update the spec

**Files:**
- Create: `docs/features/v1-user-migration.md` (project root)
- Modify: `docs/superpowers/specs/2026-09-02-email-password-auth-design.md`

- [ ] **Step 1: Write the feature doc**

Create `docs/features/v1-user-migration.md`:

```markdown
# V1 User Migration (Devise → Firebase)

One-time migration bringing 30,463 users from the pre-Firebase era of
`thegreatestbooks.org` into Firebase Authentication with their existing
passwords.

## Why hashes rather than a reset

Their bcrypt hashes are intact and unpeppered, so importing them means those
users sign in with the password they already have, through the ordinary
Firebase flow. The legacy site instead had a bespoke endpoint that decrypted
the old password server-side and created a Firebase account on the fly — an
endpoint anyone who knew an email address could drive. Importing removes the
endpoint rather than reimplementing it more carefully.

## Running it

```bash
# 1. Export (path MUST be outside the repository -- it is 30,463 password hashes)
bin/rails "firebase:export_v1_passwords[$HOME/v1-firebase-import.json]"

# 2. Import (owner runs this locally; no service account belongs in the app)
npx firebase-tools auth:import "$HOME/v1-firebase-import.json" \
  --hash-algo=BCRYPT --project the-greatest-books

# 3. Backfill the derived uids
DRY_RUN=1 bin/rails firebase:backfill_v1_uids   # preview
bin/rails firebase:backfill_v1_uids

# 4. Delete the export file
shred -u "$HOME/v1-firebase-import.json"
```

Prove the mechanism first with a single record whose password you chose:

```bash
bin/rails "firebase:canary[$HOME/canary.json,you+v1@gmail.com,a-password-you-pick]"
```

Run that import **twice** and sign in again after the second. The whole
re-run story rests on Firebase replacing a colliding `localId` rather than
duplicating it, and this is the cheapest place to confirm that holds.

## The uid

`tgbv1-<legacy_id>`, defined once in
`Services::BooksMigration::FirebasePasswordExport.uid_for`. Both the exported
`localId` and `users.auth_uid` derive from it independently, so they cannot
drift, and the backfill is idempotent and environment-independent.

This works only because `Services::BooksMigration::UserMigrator` upserts
`unique_by: :id`, so `LegacyBooks::User#id` and `User#id` are the same integer.
The backfill asserts this and aborts if any cohort id has no new-table row.

## Who is not covered

| Cohort | Count | Why |
|---|---:|---|
| No email address at all | 20,063 | v1 Facebook/Twitter logins. Unreachable by any email flow; would need those providers implemented |
| Malformed email | 46 | Signup typos (`@gmail` with no TLD, `@gmailcom`). Never deliverable. **Never repaired** — inferring a domain would create an account at an address the user does not control |
| Email but no Firebase identity | 37 | Recover via Create account, which links through the verified-email rule |

## Console settings this depends on

- **"Create multiple accounts for each identity provider" is enabled, and stays enabled.**
  An earlier version of this line said the opposite — that "one account per email
  address" must be enabled. That was never true of this project and must not be
  "fixed" by changing the console. The multi-account setting is a deliberate UX
  choice: a user can sign up with a password and later sign in with Google or
  Facebook and have it just work, because Rails links the identities by email
  lookup (`UserAuthenticationService#find_user`) rather than making them remember
  which button they first used. Confirmed by the owner 2026-09-04.
- **This does not weaken the linking rule.** The concern recorded in the spec was
  that multiple identities per address would undermine step 2. It does not: step 2
  fires only on `email_verified: true` in the JWT, and the second identity an
  attacker can create starts unverified, so step 3 refuses it. Getting
  `email_verified` requires clicking a link delivered to the address itself. The
  gate PR 1 added is what carries the security here, not the console setting.
- **Apple's "Hide My Email" is the real limitation of email-based linking.** The
  JWT then carries a `@privaterelay.appleid.com` address that matches no existing
  row, so step 2 misses and a *second Rails user* is created for the same person.
  Out of scope for this migration, but it must be designed for when Apple sign-in
  is built — matching cannot rely on the email claim alone. Note this produces
  duplicates with *different* emails, so no uniqueness constraint would catch it.
- **facebook/twitter/apple providers are enabled and stay enabled.** One Firebase
  project serves the legacy site as well, the legacy site offers those logins, and
  social login is the next feature after this migration. `PROVIDER_MAP` accepting
  them is intentional.
- Every domain must be on the **authorized domains** list, or
  `actionCodeSettings` raises `auth/unauthorized-continue-uri`. Authorized
  domains gate OAuth redirects and `actionCodeSettings` continue URLs only --
  plain email/password sign-in needs neither, which is why a missing host causes
  nothing visible until a social provider or a continue URL is involved.

  **RESOLVED 2026-09-05: every host this app serves is authorized. Confirmed by
  the owner. Do not re-raise this, and do not re-audit it from an old
  screenshot.** A 2026-09-04 audit had flagged `new.thegreatestbooks.org`,
  `dev-new.thegreatestbooks.org` and `dev.thegreatest.games` as missing; they
  were added. The finding was correct when written and is now stale -- it is
  recorded here only so the next reader does not rediscover the same closed
  issue.

  For reference, the hosts this app serves (source of truth:
  `config/initializers/domain_config.rb`, matched by the Caddyfile and
  `e2e/playwright.config.ts`):

  | | prod | dev |
  | --- | --- | --- |
  | books | `new.thegreatestbooks.org` | `dev-new.thegreatestbooks.org` |
  | music | `thegreatestmusic.org` | `dev.thegreatestmusic.org` |
  | games | `thegreatest.games` | `dev.thegreatest.games` |

  `thegreatestbooks.org`, `www.` and `dev.thegreatestbooks.org` belong to the
  legacy site and its dev host; they stay.
- Email templates are per-project and cannot vary by domain — keep them
  brand-neutral ("The Greatest").
```

- [ ] **Step 2: Correct the spec's data section**

In `docs/superpowers/specs/2026-09-02-email-password-auth-design.md`, replace
the line

```
33 email addresses are duplicated case-insensitively across 69 rows.
```

with

```
33 email addresses are duplicated case-insensitively across 69 rows — but **none
of them are in the V1 cohort**, and no cohort email collides with a row outside
it. Measured 2026-09-02. The exporter still counts duplicates as an assertion.

**46 cohort emails are malformed** (`@gmail` with no TLD, `@gmailcom`, `@123`),
32 of them holding list data. They are signup typos that were never deliverable.
The exporter skips and reports them; it must never repair them, since inferring
a domain would create a Firebase account at an address the user does not control.
```

Then, in the **Design — PR 2** section, replace the bullet

```
- Resolve the 33 duplicate addresses: keep the row with the most recent
  `last_sign_in_at`, skip and log the others.
```

with

```
- Duplicate addresses: keep the row with the most recent `last_sign_in_at`, skip
  and count the others. Zero exist in the cohort today; this stays as an
  assertion, so a non-zero count means the data changed and the run needs review.
```

- [ ] **Step 3: Note the PR-boundary change**

In the spec's **Decisions** table, append a row:

```
| D7 | The linking rule moved from PR 2 into PR 1 | Sourcing email from the JWT does not stop an attacker creating an unverified Firebase password account for a victim's address in our own project. Only the `email_verified` gate closes that, so leaving it for PR 2 would keep a known takeover live throughout the migration. |
```

- [ ] **Step 4: Run the full suite and commit**

```bash
bin/rails db:test:prepare test
bundle exec standardrb
```
Expected: 0 failures, 0 errors, no new warnings.

```bash
git add ../docs/features/v1-user-migration.md ../docs/superpowers/specs/2026-09-02-email-password-auth-design.md
git commit -m "docs: record the v1 user migration and correct the cohort data"
```

---

## Self-Review

**Spec coverage.** Export → Task 1. Import command → Tasks 2, 7. Write-back →
Task 3. Deterministic uid + the id-preservation invariant → Tasks 1, 3.
Malformed-hash and duplicate-email rejection → Task 1. Refusing in-repo output →
Tasks 1, 2. Canary → Task 2. F7 cross-domain `actionCodeSettings` → Task 4.
Failed-sign-in copy → Task 5. E2E → Task 6. Rollout and console settings →
Task 7. The linking rule and every F1–F6 item are in the PR 1 plan.

**Placeholder scan.** No TBD/TODO. Every code step carries literal code. The one
genuine unknown — the `passwordHash` encoding — is isolated in a single named
method (`encode_hash`) with the canary as its resolution and a comment naming
the two alternatives.

**Type consistency.** `FirebasePasswordExport.uid_for(legacy_id)` is defined in
Task 1 and consumed in Task 3's test; `UID_PREFIX` is defined in Task 1 and used
in Task 3's `update_slice`. `BCRYPT_GRAMMAR` is defined in Task 1 and used by the
canary task in Task 2. Both services return the `{success:, data:, error:}` shape
the `BooksMigration` migrators already use. `dry_run:` is keyword-consistent
between the service, its test and the rake task.

**Deviation from the spec, deliberate.** The linking rule is implemented in the
PR 1 plan rather than here — see D7 in Task 7, Step 3. This plan therefore has
no `UserAuthenticationService` changes and depends on PR 1 being merged.

**Not covered by tests, by nature.** The Firebase import itself and the console
settings are outside the repository. Task 2's canary is the check on the former;
Task 7's doc records the latter.
