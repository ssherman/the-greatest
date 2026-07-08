# Users Migration (legacy users → global User) — Design

**Status:** Approved 2026-07-07.
**Scope:** One migration increment on top of the merged books data (Phase 1a/1b + editions + identifiers + categories + ISBN). Migrate the legacy `users` table into the new **global** `User` model, **preserving ids**, keeping every account (including ~20k email-less legacy OAuth accounts), and preserving the data a future auth/claiming flow needs to re-unite returning V1/V2 users. Adds three columns to `users`. Unblocks `external_links` (needs `submitted_by`) and Phase 3 (user_lists need `user_id`).
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.
**Supersedes** the parent design's `users` mapping note (§Reference tables), which assumed all fields map to existing columns and dropped `external_provider_uid`/`migrated` — see Decisions.

## Goal

Get all 69,459 legacy user records into the new `users` table with **ids preserved**, faithfully (null and duplicate emails kept as-is), while **preserving the legacy auth identity** (`external_provider_uid`, the `migrated` flag, and the raw V1 `old_user_data` blob) so a later auth increment can recognize and re-claim returning legacy users. The load is idempotent and re-runnable.

## Background: three site versions (from owner, 2026-07-07)

The legacy app went through three versions. **V1 allowed email-less "login" accounts** (Devise + OmniAuth; Facebook/Twitter often returned no email). The **`migrated` flag** is true when a user had a V1 account and logged into V2 (V2 = Firebase). This app is V3. The owner wants to **keep supporting V1 and V2 users**, including V1 users who never logged into V2 — so email-less accounts must be preserved, not dropped, and the legacy OAuth identity must survive the migration so returning users can be matched later.

## Legacy data (local restore, introspected 2026-07-07)

`users`: **69,459 rows, max id 69,498**. Columns used and dropped listed under Mapping.

Data-quality facts that drive the design:

| Fact | Value | Handling |
|---|---|---|
| null email | **20,063 (29%)** | **kept** (legacy reality; model email-presence bypassed) |
| duplicate real emails | 24 emails across **51 rows** | **kept** (coexist; model uniqueness bypassed; no DB unique index on email) |
| `migrated = true` / `false` | 18,951 / 50,508 (0 null) | preserved into `legacy_migrated` |
| null-email users that are V1 OAuth logins | 20,059 have `external_provider` set (FB 17,531 / Twitter 2,516 / Apple 12 / nil 4); only 19 have `auth_uid` | preserved; matched later by `external_provider_uid` |
| null-email users owning ≥1 user_list | **all 20,063** (80,252 user_lists, **527,441** saved book entries) | **cannot drop** — Phase 3 keeps them |
| null-email users with `old_user_data` | 20,045 (12,848 contain a recoverable `provider_data.info.email`) | blob preserved; recovery **deferred** |
| `role` | 0=user 69,454 / 1=admin 2 / 2=editor 3 (0 null) | raw int copy (enums identical) |
| `external_provider` | 0-4 present + 31,406 null | raw int copy (nullable; enums identical) |
| `email_verified` | false 69,193 / true 266 (0 null) | direct |
| `sign_in_count` | 0 null | direct |
| `provider_data` | text column holding a JSON string | passthrough (new model `serialize :provider_data, coder: JSON`) |
| `auth_data` | jsonb | passthrough (new column jsonb) |

`old_user_data` is the full V1 Devise/OmniAuth record as a JSON string: top-level `email`/`encrypted_password`/`provider`/`uid`, plus a nested escaped `provider_data` whose `info.email` is the OAuth email (often present for Facebook, usually null for Twitter). This is the recovery/matching source, preserved verbatim.

## Reservation state (already done — completed reservation increment)

The `users` id range is reserved: existing/new-app users occupy ids **≥ 150,001** (sequence at 150,022); legacy ids 1-69,498 fit in the reserved 1-150,000 range. Inserting legacy users with explicit ids does not advance the sequence, so **no `setval` / sequence step is needed**.

## Decisions

- **D1 — keep every user, preserve id.** Migrate all 69,459 (no skips). The email-less accounts own 527k saved book entries and must survive for Phase 3 and URL/id continuity.
- **D2 — faithful email.** Null emails stay null; the 51 duplicate-email rows coexist. The new `User` model's `validates :email, presence: true, uniqueness: true` is **model-level only** (no DB index), so bypassing it at migration time leaves no hard constraint violated.
- **D3 — bulk `upsert_all` write path (keyed on `id`).** Reuse the `BulkUpsertMigrator` pattern. This naturally **bypasses both** the `after_create :create_default_user_lists` callback (which would otherwise spawn **12 default lists/user ≈ 833k** cross-domain `user_lists`) **and** the email validations (D2). Idempotent on `id`. Legacy `created_at`/`updated_at` are **preserved** (written explicitly; `record_timestamps: false`).
- **D4 — preserve the OAuth matching identity.** Add `external_provider_uid` (string) as a first-class, indexed column (the reliable re-match key for returning V1/V2 users), alongside the existing `external_provider` enum.
- **D5 — carry the `migrated` flag** into a new `legacy_migrated` (boolean, nullable) column so V3 can handle unmigrated/unclaimed accounts differently. Native V3 signups leave it null.
- **D6 — preserve the raw V1 blob.** Add `legacy_v1_data` (**text**, nullable, not indexed — owner: won't be queried) holding `old_user_data` verbatim (carries `provider_data.info.email` and the V1 bcrypt password for a future claiming flow).
- **D7 — defer email recovery & login matching** to a later auth increment. This increment only preserves the data (D4/D6); it does not parse blobs, recover emails, or build matching.
- **D8 — enums as raw int copy.** `role` (0-2) and `external_provider` (0-4/null) have identical integer encodings old↔new (verified); no symbol re-mapping. (Contrast the `List.status`/`Edition.book_binding` landmines — not applicable here.)

## Schema change (new Rails migration on `users`)

Add three nullable columns (all default null; no backfill for existing rows):

| column | type | purpose |
|---|---|---|
| `external_provider_uid` | `string` | legacy OAuth uid — re-match key (D4) |
| `legacy_migrated` | `boolean` | legacy `migrated` flag (D5) |
| `legacy_v1_data` | `text` | raw `old_user_data` V1 blob (D6) |

Add a composite index `index_users_on_external_provider_and_uid` on `(external_provider, external_provider_uid)` for future match lookups. Generate via `bin/rails generate migration`. Re-annotate `user.rb`.

## Source → target mapping (`users` → `users`, preserve id)

| new column | legacy source | handling |
|---|---|---|
| `id` | `id` | **preserved** (explicit) |
| `email` | `email` | direct (may be null; kept) |
| `name` | `name` | direct |
| `display_name` | `display_name` | direct |
| `photo_url` | `photo_url` | direct |
| `auth_uid` | `auth_uid` | direct (null for most V1) |
| `auth_data` | `auth_data` | jsonb passthrough |
| `provider_data` | `provider_data` | **parse** the legacy JSON string to a Hash before upsert (the new column's `serialize coder: JSON` re-encodes; passing the raw string would double-encode). Blank/nil → nil |
| `email_verified` | `email_verified` | direct (0 nulls; NOT NULL default false) |
| `external_provider` | `external_provider` | raw int (nullable) |
| `role` | `role` | raw int (NOT NULL) |
| `sign_in_count` | `sign_in_count` | direct |
| `last_sign_in_at` | `last_sign_in_at` | direct |
| `stripe_customer_id` | `stripe_customer_id` | direct |
| `created_at` / `updated_at` | same | **preserved** (`record_timestamps: false`) |
| `external_provider_uid` | `external_provider_uid` | **new** (D4) |
| `legacy_migrated` | `migrated` | **new** (D5) |
| `legacy_v1_data` | `old_user_data` | **new** (D6) |

Left null / unset (no legacy equivalent): `confirmation_sent_at`, `confirmation_token`, `confirmed_at`, `original_signup_domain`.

Dropped legacy columns: `name_from_oauth`, `joined_email_list`, `old_encrypted_password` (also inside `old_user_data`), `first_login_confirmation`, `paid`, `goodreads_import`.

## Migrator

`Services::BooksMigration::UserMigrator` — a `BulkUpsertMigrator` subclass: `legacy_model = LegacyBooks::User`, `target_model = User`, `unique_by: :id`. `build_rows` maps each legacy attribute hash to a new-column row hash per the table above (raw int enums, legacy `created_at`/`updated_at` included, blob/uid/flag preserved). New `LegacyBooks::User` read-only model (`self.table_name = "users"`). No `finalize` (no counter caches; sequence already reserved). Idempotent on `id`.

**Base tweak (timestamp preservation).** The `BulkUpsertMigrator` base's `flush` hardcodes `record_timestamps: true`, which would overwrite the legacy timestamps we pass. Extract that into a small overridable hook — `def record_timestamps? = true` on the base, used by `flush` — and override it to `false` in `UserMigrator` (which supplies `created_at`/`updated_at` itself). This is a minimal, backward-compatible change: every existing subclass keeps `true`.

Fail-loud: users have **no inbound FK to remap** (they are a root entity), so there is no missing-prerequisite case here — unlike the book/category migrators. The migrator still surfaces per-batch errors via the base.

## Orchestration

Add `data_migration:users` task calling `UserMigrator.call`. Insert `:users` into `data_migration:all` in dependency order — after `languages`, before/independent of the books entities (users are referenced later by lists/external_links/user_lists, not by books). Recommended position in `:all`: `[:languages, :users, :authors, :books, …]` (matches the parent design's order).

## Testing (Minitest + Mocha, stub `legacy_each`/streaming)

- Maps a fully-populated legacy row to the correct new columns incl. `external_provider_uid`, `legacy_migrated`, `legacy_v1_data`; id preserved.
- Null email is kept (row inserts; email nil) — proves validations bypassed.
- Duplicate emails across two rows both insert (no uniqueness error).
- `create_default_user_lists` does **not** fire: `assert_no_difference -> { UserList.count }` (0 default lists created).
- Enums stored as raw ints (`role`, `external_provider`), nil `external_provider` preserved.
- Legacy `created_at`/`updated_at` preserved (not overwritten with "now").
- `migrated` true/false → `legacy_migrated`; `old_user_data` → `legacy_v1_data` verbatim.
- Idempotent: re-run leaves `User.count` unchanged and updates in place.
- `provider_data` JSON string round-trips (stored value readable by the model's `serialize`).

## E2e verification (controller-run against the real legacy DB)

Reset dev DB to the migrated baseline, run `data_migration:users`, then verify:
- `User.count` rises by 69,459 (legacy total); ids 1-69,498 present; min legacy id = 1, no collision with the reserved ≥150,001 range.
- Null-email count == 20,063; duplicate-email rows preserved; `legacy_migrated` true/false split == 18,951/50,508.
- `external_provider_uid` populated for the ~20k OAuth accounts; `legacy_v1_data` present where legacy `old_user_data` was.
- **No default `user_lists` were created** by the load (UserList count unchanged).
- Idempotent: a second run leaves `User.count` unchanged.
- `role`/`external_provider` distributions match legacy exactly.
- Full suite green; standardrb + brakeman clean.

## Out of scope (future auth increment)
- Parsing `old_user_data` / recovering `provider_data.info.email` into `email`.
- Login-time matching/claiming of returning V1/V2 users (by `external_provider_uid` or recovered email).
- De-duplicating the 51 duplicate-email accounts or the multi-account users.
- `Books::UserList` STI subclass and any `user_lists`/`user_list_items` migration (Phase 3).
- `original_signup_domain` backfill (left null; could be set to the books domain later).

## References
- Parent design: `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`
- Reservation: `docs/specs/completed/books-migration-01-id-range-reservation.md`, `app/lib/services/books_migration.rb`
- `BulkUpsertMigrator`: `app/lib/services/books_migration/bulk_upsert_migrator.rb` (categories increment)
- `User` model: `app/models/user.rb`; `UserList` (default lists): `app/models/user_list.rb`
