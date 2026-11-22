# Admin MCP List Audits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent (Codex) research a books list over the admin MCP and directly correct its metadata and penalties, with each run recorded as an audit; give the public MCP read-only penalties.

**Architecture:** Ten new admin REST operations in `config/api/v1/admin_openapi.yaml` (each with an `x-mcp` block, so `Mcp::Catalog` turns them into tools) backed by small services under `app/lib/services/lists/`. A new `list_audits` table brackets a run with server-side snapshots. Agent rules live on a new `penalties.guidance` column. Admin pages get a list-audit queue page and per-list Copy audit prompt; the public document gains `GET /api/v1/penalties` and `penalties` on a list's full shape.

**Tech Stack:** Rails 8.1, Minitest + fixtures, Alba resources, the `mcp` gem via `Mcp::Catalog`, ViewComponents + DaisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-21-admin-mcp-list-audits-design.md` (approved by Shane 2026-11-21)

## Global Constraints

- Run Rails/yarn commands from `web-app/`. Lint is `bundle exec standardrb`, never rubocop/brakeman.
- Generators for models/migrations/controllers/components (`bin/rails generate ...`); `bin/rails db:migrate` runs annotaterb; never set `ANNOTATERB_SKIP_ON_DB_TASKS`. The dev DB is shared: delete annotation lines for columns this branch's `schema.rb` lacks, never skip the run.
- Never run destructive commands against development (the hook blocks them). Data changes go through rake tasks run deliberately.
- Every model reference inside `Api::V1::Admin::Books` and `Api::V1::Books` is root-anchored (`::Books::List`, `::Penalty`).
- Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Books only. Penalties applicable to books lists = `::Penalty.where(type: %w[Books::Penalty Global::Penalty], user_id: nil)` — call this "the books catalogue".
- "The default primary configuration" = `::Books::RankingConfiguration.default_primary` (may be nil; every read must survive nil).
- Editable list fields (exactly these, called UPDATE_FIELDS below): `name description source source_country_origin url year_published number_of_voters num_years_covered yearly_award high_quality_source category_specific location_specific creator_specific voter_count_estimated voter_count_unknown voter_names_unknown estimated_quality`. Never `status`, `raw_content`, `simplified_content`, `items_json`, `wizard_state`, `auto_generated_*`.
- `ListAudit::LEASE = 3.hours`.
- Every write tool's `x-mcp` description says: "The list's weight does not change until an admin refreshes the ranking configuration."
- Minitest 6: `assert_nil`, never `assert_equal nil`. Controller tests assert behaviour, not copy. A clean `bin/rails test` prints no new warnings.

## Review Focus

1. **Two agents call `start_list_audit` with no id at the same moment** → they must get different lists, never the same one and never a 500. Pinned by a test in Task 3 that pre-inserts a competing in-progress audit on the first queued list between the pick and the insert (stub) and expects the next list.
2. **A `finish` arriving after the lease expired** → accepted while no newer audit exists on the list; refused (409) once another start has superseded it. Pinned in Task 3.
3. **Attaching something that is not a catalogue static penalty** (a dynamic one, a music penalty, a user-owned penalty, an unknown id) → 422 with a reason that, for a dynamic penalty, names the list field to set instead; nothing written. Pinned in Task 5.
4. **`update_admin_list` with wrong types or impossible values** (`"12"` for a count, `num_years_covered: 0`, `null` for a boolean flag, `status`) → 400/422, nothing written. Pinned in Task 5.
5. **Public `get_list` for a list with no ranked list on the configuration, or with null `calculated_weight_details`** → `penalties: []`, never 500. Pinned in Task 8.

---

### Task 1: Penalty guidance column, admin form field, loader and the stray dynamic attachment

**Files:**
- Create: migration `AddGuidanceToPenalties` (via `bin/rails g migration AddGuidanceToPenalties guidance:text`)
- Modify: `web-app/app/models/penalty.rb` (add `DRIVING_FIELDS`), `web-app/app/controllers/admin/penalties_controller.rb:69` (permit `:guidance`), `web-app/app/views/admin/penalties/_form.html.erb` (textarea after description), `web-app/app/views/admin/penalties/show.html.erb` (show it)
- Create: `web-app/config/penalties/guidance.yml`, `web-app/lib/tasks/penalties.rake`, `web-app/app/lib/services/penalties/load_guidance.rb`, `web-app/app/lib/services/penalties/detach_dynamic.rb`
- Test: `web-app/test/models/penalty_test.rb`, `web-app/test/lib/services/penalties/load_guidance_test.rb`, `web-app/test/lib/services/penalties/detach_dynamic_test.rb`, `web-app/test/controllers/admin/penalties_controller_test.rb`

**Interfaces:**
- Produces: `penalties.guidance` (text, nullable); `Penalty::DRIVING_FIELDS` (Hash dynamic_type String → list field String or nil):
  `{"number_of_voters" => "number_of_voters", "voter_names_unknown" => "voter_names_unknown", "voter_count_unknown" => "voter_count_unknown", "voter_count_estimated" => "voter_count_estimated", "category_specific" => "category_specific", "location_specific" => "location_specific", "num_years_covered" => "num_years_covered", "creator_specific" => "creator_specific", "percentage_western" => nil}`;
  `Penalty#driving_field -> String|nil` (`DRIVING_FIELDS[dynamic_type]`);
  `Services::Penalties::LoadGuidance.call(entries:) -> Result` data `{filled: [ids], skipped_present: [ids], mismatched: [{id:, expected:, actual:}], missing: [ids]}` where `entries` is the parsed YAML Array of `{"id", "name", "guidance"}`;
  `Services::Penalties::DetachDynamic.call(dry_run:) -> Result` data `{list_penalty_ids: [...]}`.

- [ ] **Step 1: Write the failing tests**
  - `penalty_test.rb`: `test "driving_field names the list field behind each dynamic type"` — `assert_equal "num_years_covered", Penalty.new(dynamic_type: :num_years_covered).driving_field`; `assert_nil Penalty.new(dynamic_type: :percentage_western).driving_field`; `assert_nil Penalty.new.driving_field`; and `assert_equal Penalty.dynamic_types.keys.sort, Penalty::DRIVING_FIELDS.keys.sort`.
  - `load_guidance_test.rb`: fills a blank `guidance` when id and name match; leaves a non-blank one (`skipped_present`); reports a name mismatch without writing; reports an id with no row in `missing`; running twice changes nothing the second time.
  - `detach_dynamic_test.rb`: create a `ListPenalty` for `penalties(:dynamic_penalty)` with `save(validate: false)`; `dry_run: true` returns its id and leaves it; `dry_run: false` destroys it and leaves static attachments alone.
  - `penalties_controller_test.rb`: PATCH with `penalty: {guidance: "Rule"}` persists it.
- [ ] **Step 2: Run them, expect failures** — `bin/rails test test/models/penalty_test.rb test/lib/services/penalties test/controllers/admin/penalties_controller_test.rb` → errors (no column / constant / service).
- [ ] **Step 3: Implement.** Generate and run the migration (`bin/rails db:migrate`, annotations updated). Add the constant/method, permit + form textarea (`fieldset` + `fieldset-legend`, `textarea w-full`, hint "How an agent decides whether this penalty applies. Not shown to readers."), the two services, and `penalties.rake`:
  - `penalties:load_guidance` reads `config/penalties/guidance.yml`, calls `LoadGuidance`, prints the four buckets.
  - `penalties:detach_dynamic` calls `DetachDynamic` with `dry_run: ENV["APPLY"] != "1"` and prints the ids.
- [ ] **Step 4: Write `config/penalties/guidance.yml`** from Appendix A of this plan (one entry per penalty: `id`, `name` exactly as in the DB, `guidance`). This text is a draft for Shane; do not reword its rules.
- [ ] **Step 5: Run the tests, expect PASS;** then `bin/rails penalties:load_guidance` against dev and check every Appendix A id lands in `filled` (none `mismatched`/`missing`). `bin/rails penalties:detach_dynamic` (dry run) lists exactly one id.
- [ ] **Step 6: Commit** — `git commit -m "Penalties: agent guidance column, guidance loader, stray dynamic attachment cleanup"`

### Task 2: `ListAudit` model and snapshot/diff

**Files:**
- Create: `ListAudit` via `bin/rails g model ListAudit list:references user:references status:integer verdict:integer lease_expires_at:datetime started_at:datetime finished_at:datetime before:jsonb after:jsonb field_changes:jsonb note:text sources:jsonb` (edit the migration: `status` default 0 null false; `sources` default `[]` null false; user FK `on_delete: :nullify`, user nullable; partial unique index `index_list_audits_one_open_per_list` on `list_id` WHERE `status = 0`; index on `[status, finished_at]`)
- Create: `web-app/app/lib/services/lists/audits/snapshot.rb`, `web-app/app/lib/services/lists/audits/diff.rb`
- Modify: `web-app/app/models/list.rb` (`has_many :list_audits, dependent: :destroy`)
- Test: `web-app/test/models/list_audit_test.rb`, `web-app/test/lib/services/lists/audits/snapshot_test.rb`, `web-app/test/lib/services/lists/audits/diff_test.rb`, fixture `web-app/test/fixtures/list_audits.yml`

**Interfaces:**
- Produces: `ListAudit` with `LEASE = 3.hours`; `enum :status, {in_progress: 0, finished: 1, released: 2}`; `enum :verdict, {verified: 0, unverifiable: 1}`; `belongs_to :list`, `belongs_to :user, optional: true`; scopes `open` (in_progress and `lease_expires_at > now`), `expired` (in_progress and `lease_expires_at <= now`), `done` (finished); `#expired? -> Boolean`. The spec's `changes` column is named `field_changes` (a `changes` column would collide with `ActiveRecord::Dirty#changes`); the API still calls it `changes`.
- `Services::Lists::Audits::Snapshot::FIELDS` = UPDATE_FIELDS (the Global Constraints list, as Strings, in that order).
- `Services::Lists::Audits::Snapshot.call(list) -> Hash` `{"fields" => {field => value}, "penalties" => [{"id" => Integer, "name" => String}, ...] sorted by id}`.
- `Services::Lists::Audits::Diff.call(before:, after:) -> Hash` `{"fields" => {field => {"from" => x, "to" => y}} (only changed), "penalties_attached" => [{"id","name"}], "penalties_detached" => [{"id","name"}]}`; `Diff.empty?(diff) -> Boolean`.
- Fixtures `list_audits.yml`: `books_verified_audit` (list `books_list`, finished, verified, finished 2 days ago, user `admin_user` — check `test/fixtures/users.yml` for the real admin fixture name). No in-progress fixture (tests create their own).

- [ ] **Step 1: Write the failing tests** — `list_audit_test.rb`: the DB refuses a second in-progress audit on one list (`assert_raises(ActiveRecord::RecordNotUnique)`), but allows a second once the first is `released`; `open`/`expired` split on `lease_expires_at` (use `travel`). `snapshot_test.rb`: returns exactly `Snapshot::FIELDS` keys and the attached penalties sorted by id. `diff_test.rb`: a changed field appears with from/to, an unchanged one does not; an attached and a detached penalty land in their arrays; `Diff.empty?` true for identical snapshots.
- [ ] **Step 2: Run, expect failures.** `bin/rails test test/models/list_audit_test.rb test/lib/services/lists/audits`
- [ ] **Step 3: Implement** (migrate; annotations; model; services).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "List audits: model, snapshot and diff"`

### Task 3: Audit queue and the Start / Finish / Release services

**Files:**
- Create: `web-app/app/lib/services/lists/audits/queue.rb`, `start.rb`, `finish.rb`, `release.rb`, `counts.rb` (all under `app/lib/services/lists/audits/`)
- Test: matching files under `web-app/test/lib/services/lists/audits/`

**Interfaces:**
- Consumes: Task 2's `ListAudit`, `Snapshot`, `Diff`.
- Produces:
  - `Queue.relation -> ActiveRecord::Relation<::Books::List>`: status `active` or `approved`; `auto_generated_kind IS NULL`; no `finished` audit; no `open` audit. Order: lists never started first, then lists whose latest released/expired audit started earliest (`MAX(list_audits.started_at)` NULLS FIRST), then weight on the default primary configuration DESC NULLS LAST, then `lists.id`. With no default primary, skip the weight term.
  - `Queue.remaining -> Integer` (`relation.count` without the order).
  - `Start.call(user:, list: nil) -> Result` data `{audit: ListAudit|nil, resumed: Boolean, remaining: Integer}`. With `list`: `user` already holds an open audit on it → that audit, lease renewed, `resumed: true`; another user holds one → failure, `errors: ["List N is being audited by <user name or email> until <iso8601>"]` and `data: {conflict: true}`; an expired one → mark it `released` with note "lease expired" then open a new one. Without `list`: take `Queue.relation.first`, insert, and on `ActiveRecord::RecordNotUnique` retry with the next (up to 5 tries); none → success with `audit: nil`. New audit: `status: in_progress`, `started_at: now`, `lease_expires_at: now + LEASE`, `before: Snapshot.call(list)`. Any books list may be started by id (including unapproved, rejected, generated); a non-books list is the caller's 404, not this service's concern.
  - `Finish.call(audit:, user:, verdict:, note:, sources:) -> Result` data `{audit:}`. Refuse (with `data: {conflict: true}`) unless `audit.in_progress?` and `audit.user_id == user.id`. Refuse (422-style, no conflict flag) a verdict outside `verified`/`unverifiable`, a blank note, `sources` not an Array of http(s) URL Strings, or empty `sources` with `verified`. On success: `after: Snapshot.call(list)`, `field_changes: Diff.call(...)`, `status: finished`, `finished_at: now`, `lease_expires_at: nil`.
  - `Release.call(audit:, user:, note: nil, admin: false) -> Result`: refuse unless in progress and (`admin` or holder). Sets `released`, `finished_at: now`, appends note.
  - `Counts.call -> Hash` `{not_audited: Queue.remaining, verified:, unverifiable:, in_progress:}` (the last three over books lists only).

- [ ] **Step 1: Write the failing tests.** Queue: an active never-audited list is in it; a list with a finished audit (either verdict) is not; an unapproved list and a generated list are not; a list whose audit was released sorts after every never-started list; heavier lists first among never-started ones (create two `RankedList` rows on the default primary fixture config with weights 10 and 90). Start: resumes the caller's own open audit (same id, later `lease_expires_at`); refuses another user's open audit with `data[:conflict]`; replaces an expired one (old row `released`); no-id picks the queue head; **Review Focus 1** — stub `Queue.relation` to return [a, b] and pre-insert an in-progress audit on `a` from another user before calling, expect the audit on `b`; empty queue → `audit: nil`, success. Finish: **Review Focus 2** — `travel 4.hours` then finish succeeds when nothing superseded it; after another user's Start replaced it, finish fails with `conflict`; diff records a field edited between start and finish; `verified` without sources refused; non-URL source refused. Release: holder can, other user cannot, `admin: true` can. Counts: numbers match the fixtures plus created rows.
- [ ] **Step 2: Run, expect failures.** `bin/rails test test/lib/services/lists/audits`
- [ ] **Step 3: Implement.** The queue relation is SQL (`LEFT JOIN` a subquery of `MAX(started_at)` per list over non-finished audits, `NOT EXISTS` for finished/open, `LEFT JOIN ranked_lists` on the primary config).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "List audits: queue, start, finish, release, counts"`

### Task 4: Admin read tools — search_admin_lists, get_admin_list, list_admin_list_items, list_admin_penalties

**Files:**
- Create: `web-app/app/controllers/api/v1/admin/books/lists_controller.rb` (`index`, `show`), `list_items_controller.rb` (`index`), `penalties_controller.rb` (`index`) under `app/controllers/api/v1/admin/books/`
- Create: resources `web-app/app/lib/api/v1/admin/books/list_resource.rb` (row + `:full` trait), `list_item_resource.rb`, `penalty_resource.rb`, `list_audit_resource.rb`
- Modify: `web-app/config/routes.rb` (admin API block near line 786), `web-app/config/api/v1/admin_openapi.yaml` (4 paths, schemas `AdminList`, `AdminListFull`, `AdminListDetail`, `AdminListCollection`, `AdminListItem`, `AdminListItemCollection`, `AdminPenalty`, `AdminPenaltyCollection`, `AdminListAudit`)
- Test: `web-app/test/controllers/api/v1/admin/books/lists_controller_test.rb`, `list_items_controller_test.rb`, `penalties_controller_test.rb`; `web-app/test/integration/api/v1/admin_contract_coverage_test.rb` (new EXERCISES rows); `web-app/test/lib/mcp/admin_catalog_test.rb` and `web-app/test/lib/mcp/tool_directory_test.rb` (admin counts 65 → 69 here, in both files; Tasks 5 and 6 bump again)

**Interfaces:**
- Consumes: `Penalty#driving_field`, `ListAudit`, `Services::Lists::Audits::Queue` (for nothing but the `audit` filter's `not_audited` meaning, which must equal "no finished audit").
- Produces routes (all `books:admin:read`, ids `/\d+/`): `GET /api/v1/admin/lists` (`searchAdminLists` → tool `search_admin_lists`), `GET /api/v1/admin/lists/{id}` (`getAdminList` → `get_admin_list`), `GET /api/v1/admin/lists/{id}/items` (`listAdminListItems` → `list_admin_list_items`), `GET /api/v1/admin/penalties` (`listAdminPenalties` → `list_admin_penalties`).
- `search_admin_lists` params: `q` (optional; `List.search_text`), `status` (`unapproved|approved|rejected|active`), `audit` (`not_audited|verified|unverifiable|in_progress`), `sort` (`weight` default | `name` | `id`), `page`, `per_page`. Only `::Books::List`. Row: `id name source year_published status item_count weight last_audit` where `last_audit` is `{id, status, verdict, finished_at}` or null; `weight` is on the default primary configuration (null off it).
- `get_admin_list` (`:full`): row keys + every UPDATE_FIELD + `url`, `auto_generated` (Boolean), `has_raw_content` (Boolean), `penalties` (attached: `id name kind category value_on_primary` where `kind` is `static|dynamic` and `value_on_primary` is the `PenaltyApplication.value` on the default primary or null), `weight_details` (`calculated_weight_details` of the primary ranked list, or null) and `weight_computed_at` (that ranked list's `updated_at`), `open_audit` (`ListAuditResource` or null), `audits` (last 5 finished/released, newest first, `ListAuditResource`). `ListAuditResource`: `id status verdict user_name started_at finished_at lease_expires_at note sources changes` (`changes` = `field_changes`).
- `list_admin_list_items`: paged in `position` order (nulls last, then id); row `id position verified book` where `book` is `{id, title, authors: [names], first_published_year, countries: [names]}` or null, plus `text` (the item's metadata title/author text for unlinked rows: `metadata["title"]`, `metadata["author"]` or `metadata["authors"]` — read `ListItem` metadata in a few fixtures/dev rows to settle the keys). Avoid N+1: preload `listable: [:authors, :countries]`.
- `list_admin_penalties`: the books catalogue, not paged (≤ 50 rows), ordered by `category` then `name`; row `id name type kind dynamic_type driving_field category category_title description guidance value_on_primary books_list_count`.
- `x-mcp` descriptions (write them in the house style of `getAdminSeries`): `get_admin_list` says to read `list_admin_penalties` first and that `value_on_primary` null means the penalty costs nothing on the main ranking; `list_admin_penalties` says static ones are attached with `attach_list_penalty` and dynamic ones are never attached — set their `driving_field` with `update_admin_list`; and that a null `number_of_voters` or `num_years_covered` means no penalty from that curve.

- [ ] **Step 1: Write the failing tests.** Controller tests (host `dev-new.thegreatestbooks.org`, `bearer(ApiTokenSecrets::ADMIN_READ)`, `assert_api_response_conform(status: 200, api: :admin)`): search returns only Books lists; `audit=verified` returns the fixture-audited list and `audit=not_audited` excludes it; `status=bogus` → 400; show of a `music_albums_list` id → 404; show carries `value_on_primary: nil` for a penalty without an application on the primary; items in position order with nulls last; penalties lists no `Movies::Penalty`/`Music::Penalty`/user-owned rows and includes `driving_field` for `dynamic_penalty`; member token → 403. Contract coverage rows for 200/400/401/403/404/429 as documented. Catalog tests: add the 4 tool names; counts 65 → 69.
- [ ] **Step 2: Run, expect failures.** `bin/rails test test/controllers/api/v1/admin/books test/integration/api/v1/admin_contract_coverage_test.rb test/lib/mcp`
- [ ] **Step 3: Implement** controllers (`BaseController` subclass; `render_page` like `SeriesController#index`; `param_in` for enums), resources, routes, OpenAPI.
- [ ] **Step 4: Run, expect PASS**, plus `CI=1 bin/rails zeitwerk:check`.
- [ ] **Step 5: Commit** — `git commit -m "Admin API: list, list item and penalty reads"`

### Task 5: Admin write tools — update_admin_list, attach_list_penalty, detach_list_penalty

**Files:**
- Modify: `web-app/app/controllers/api/v1/admin/field_update.rb` (new type `:count_or_null`), `web-app/app/controllers/api/v1/admin/books/lists_controller.rb` (`update`), routes, OpenAPI (`AdminListUpdateRequest`, `AdminListPenaltyAttachRequest`)
- Create: `web-app/app/lib/services/lists/admin_update.rb`, `web-app/app/lib/services/lists/penalty_links.rb`, `web-app/app/controllers/api/v1/admin/books/list_penalties_controller.rb`
- Test: `web-app/test/lib/services/lists/admin_update_test.rb`, `penalty_links_test.rb`, controller tests, contract coverage, catalog counts 69 → 72, `DESTRUCTIVE` gains `detachListPenalty`

**Interfaces:**
- Produces routes: `PATCH /api/v1/admin/lists/{id}` (`updateAdminList`, `books:admin:write`), `POST /api/v1/admin/lists/{id}/penalties` body `{penalty_id}` (`attachListPenalty`, write), `DELETE /api/v1/admin/lists/{id}/penalties/{penalty_id}` (`detachListPenalty`, write, `x-mcp destructive: true`).
- Field types for `update_fields` (`fields:` hash): `name` `:string`; `description source source_country_origin url` `:string_or_null`; `year_published` `:year`; `number_of_voters num_years_covered estimated_quality` `:count_or_null` (null clears; else an Integer ≥ 0, else `InvalidParameter` "… must be a non-negative integer or null"); the eight booleans `:boolean` (null refused as 400 — they are flags). `clearable:` = `%w[description source source_country_origin url year_published number_of_voters num_years_covered estimated_quality]`. `policy: ::Books::ListPolicy`.
- `Services::Lists::AdminUpdate.call(list:, attrs:, user:, via:, explicit_nulls:) -> Result` data `{changed: [field names whose value changed]}`; errors = model validation messages (so `num_years_covered: 0` → 422 from `List` validation).
- `Services::Lists::PenaltyLinks.attach(list:, penalty_id:) -> Result` data `{penalty:, changed: Boolean}`; refuses: no catalogue penalty with that id → "Penalty N is not a books list penalty (see list_admin_penalties)."; dynamic → "Penalty N is dynamic: set <driving_field> with update_admin_list instead." (for `percentage_western`: "…is computed from the list's books and never attached."); otherwise `ListPenalty` validation messages. Already attached → success, `changed: false`.
- `PenaltyLinks.detach(list:, penalty_id:) -> Result` data `{changed: Boolean}`; not attached → success `changed: false`.
- Both responses render the list in the `get_admin_list` shape plus `changed`.

- [ ] **Step 1: Write the failing tests.** **Review Focus 4**: `"12"` for `number_of_voters` → 400; `num_years_covered: 0` → 422; `high_quality_source: null` → 400; `status` key → 422 naming the editable fields; nothing written in each (`assert_no_changes -> { list.reload.attributes }`). Happy path: PATCH `{number_of_voters: 12, voter_count_estimated: true, description: null}` → 200, `changed` lists the three, values persisted. Read token → 403. **Review Focus 3**: attach `dynamic_penalty` → 422 whose detail contains `number_of_voters`; attach `music_penalty` → 422; attach `user_penalty` → 422; attach unknown id → 422; attach `global_penalty` twice → 200 both, second `changed: false`, one row. Detach not-attached → 200 `changed: false`.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS** (controller, service, contract coverage, catalog).
- [ ] **Step 5: Commit** — `git commit -m "Admin API: edit a list's fields and attach or detach its penalties"`

### Task 6: Audit tools — start_list_audit, finish_list_audit, release_list_audit

**Files:**
- Create: `web-app/app/controllers/api/v1/admin/books/list_audits_controller.rb`
- Modify: routes, OpenAPI (`AdminListAuditStartRequest`, `AdminListAuditFinishRequest`, `AdminListAuditReleaseRequest`, `AdminListAuditStart`), catalog counts 72 → 75 (no change to `config/mcp/books/admin_instructions.md`: since main 8e84d8560 admin agents already act without asking; `detach_list_penalty`'s description follows that "check, then act" wording)
- Test: `web-app/test/controllers/api/v1/admin/books/list_audits_controller_test.rb`, contract coverage

**Interfaces:**
- Consumes: Task 3 services; Task 4 `ListResource` `:full` and `ListAuditResource`.
- Produces routes (all `books:admin:write`): `POST /api/v1/admin/list_audits` body `{list_id?}` (`startListAudit`); `POST /api/v1/admin/list_audits/{id}/finish` body `{verdict, note, sources}` (`finishListAudit`); `POST /api/v1/admin/list_audits/{id}/release` body `{note?}` (`releaseListAudit`).
- Start response 200: `{data: {audit: ListAuditResource, resumed: Boolean, list: <get_admin_list shape>}, meta: {remaining: Integer}}`; empty queue: `{data: null, meta: {remaining: 0}}`. `list_id` of a non-books or missing list → 404. Conflict → 409 with the service's message.
- Finish response 200: `{data: ListAuditResource}`; conflict → 409; invalid verdict/note/sources → 422; unknown key → 422; audit id missing → 404.
- Release response 200: `{data: ListAuditResource}`; not holder → 409.
- `x-mcp` text: start says "call with no list_id to take the next unaudited list; call with list_id to audit that list; calling again on a list you are auditing resumes it"; finish says what `verified` and `unverifiable` mean (spec section 2) and that the response's `changes` is computed by the server.

- [ ] **Step 1: Write the failing tests:** start with no id returns a list and `remaining`; start twice on one id by the same token → same audit id, `resumed: true`; another admin token (`ApiTokenSecrets::ADMIN` vs the write token of a second admin — check `test/support` for available token secrets and their users; create a second admin token in the test if needed) → 409; finish happy path returns `changes` containing a field changed via PATCH in between; finish `verified` with `sources: []` → 422; release then start no-id does not return that list first when another unaudited list exists.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "Admin API: start, finish and release list audits"`

### Task 7: The audit prompt (queue and per-list)

**Files:**
- Create: `web-app/config/mcp/books/prompts/list_audit.md.erb`
- Modify: `web-app/app/lib/services/agent_prompts.rb` (add `self.for_list_audit(list: nil) -> String`)
- Test: `web-app/test/lib/services/agent_prompts_test.rb`

**Interfaces:**
- Produces: `Services::AgentPrompts.for_list_audit(list: nil) -> String`. Locals: `mcp_url`, `remaining` (`Audits::Queue.remaining`), `list` (nil in queue mode), `list_block` (String: the list's id, name, source, url, year, every UPDATE_FIELD as `field: value` with nulls written `null`, attached penalties as `id — name (static|dynamic)`, weight on the primary and its penalties from `weight_details`), `primary_median_voters` (`default_primary&.median_voter_count`).
- Template content, in this order (Shane's voice, like `series.md.erb`): what this is and why (weights drive the ranking; make each list as accurate as the sources allow); single-list mode embeds `list_block` and says "call start_list_audit with list_id N"; queue mode says "call start_list_audit with no list_id, audit that list, finish it, repeat until it returns no list (`remaining` is 0)"; research rules carried from `Admin::Lists::ResearchPromptModalComponent#research_prompt` (contributors counted conservatively, lower-middle of a plausible range; mark each fact confirmed/estimated/unknown; judge source reputation; yearly/recurring; genre; region; description for readers of The Greatest Books, 2–4 sentences: criteria, purpose, methodology, credibility); penalty rules: read `list_admin_penalties` once and follow each `guidance`, attach/detach static ones, set the fields behind dynamic ones, never attach a dynamic one; a null `number_of_voters` or `num_years_covered` means no penalty from that curve — leave `num_years_covered` null for an all-time list, and set `voter_count_unknown` rather than leaving the count null when the count cannot be found; median voters on the main ranking is `primary_median_voters`; `high_quality_source` cuts the list's total penalty by a third, so set it only for well-established, reputable sources; a penalty with `value_on_primary` null costs nothing today but is still recorded when it is true; geographic scope = `location_specific` plus exactly one static geographic penalty (the narrowest that fits); do not change `status`, recommend it in the note; edits do not change the weight until Shane refreshes; finish every list with `finish_list_audit` (verdict, a note listing what changed and why with confidence, and source URLs), or `release_list_audit` if interrupted; "You are authorised to act without asking me."
- [ ] **Step 1: Write the failing tests:** queue mode includes the MCP url, `start_list_audit`, `finish_list_audit`, `list_admin_penalties`, the remaining count; per-list mode includes the list's name, `list_id #{list.id}`, each attached penalty name, `number_of_voters: null` for a list without one; both say "authorised to act without asking".
- [ ] **Step 2: Run, expect failures.** `bin/rails test test/lib/services/agent_prompts_test.rb`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "List audits: agent prompt for the queue and for one list"`

### Task 8: Public read-only penalties

**Files:**
- Create: `web-app/app/controllers/api/v1/books/penalties_controller.rb`, `web-app/app/lib/api/v1/books/penalty_resource.rb`, `web-app/app/lib/services/lists/penalties_in_effect.rb`
- Modify: `web-app/app/lib/api/v1/books/list_resource.rb` (`:full` gains `penalties`, param-fed), `web-app/app/controllers/api/v1/books/lists_controller.rb#show` (and the ranking-configuration list show) pass `penalties:`, `web-app/config/api/v1/openapi.yaml` (`GET /api/v1/penalties` with `x-mcp` name `list_penalties`; `Penalty` schema; `ListFull` gains `penalties`), routes
- Test: `web-app/test/controllers/api/v1/books/penalties_controller_test.rb`, `lists_controller_test.rb`, `web-app/test/lib/services/lists/penalties_in_effect_test.rb`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, pin tests: `test/lib/mcp/admin_catalog_test.rb` ("public catalogue" 37 → 38), `test/lib/mcp/tool_directory_test.rb` (38 → 39, 37 → 38), `test/controllers/developers_controller_test.rb` (38 → 39), `test/controllers/api/v1/openapi_controller_test.rb` (path list)

**Interfaces:**
- `Services::Lists::PenaltiesInEffect.call(ranked_list) -> Array<::Penalty>`: the penalty ids in `ranked_list&.calculated_weight_details&.dig("penalties")` (every entry with a `penalty_id`), loaded and ordered by category then name; `[]` for nil ranked list or nil/blank details.
- `Api::V1::Books::PenaltyResource`: `name category category_title description` (`category_title` = `Penalty.category_title(category)`). No ids, values, guidance or flags.
- `GET /api/v1/penalties` (`books:read`): the books catalogue, not paged, wrapped as `{data: [...]}`; `x-mcp` description: what penalties are, that they lower a list's weight, and to use `get_list` to see which apply to one list.
- `ListResource` `:full`: `attribute :penalties { params.fetch(:penalties).map { PenaltyResource.new(_1).to_h } }` after `source_url`.
- [ ] **Step 1: Write the failing tests:** `/api/v1/penalties` lists catalogue names and no `Movies::Penalty`; list show carries the names from its ranked list's details; **Review Focus 5** — a list with no ranked list on the configuration and one with `calculated_weight_details: nil` both return `penalties: []` with 200; public responses conform (`assert_api_response_conform(status: 200)`); pin counts.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "Public API: penalties catalogue and the penalties on a list"`

### Task 9: Admin UI — list audit queue page, per-list prompt and audit history, lists index column

**Files:**
- Create: `web-app/app/controllers/admin/books/list_audits_controller.rb` (`index`, `release`), `web-app/app/views/admin/books/list_audits/index.html.erb`, component `Admin::Lists::AuditsComponent` (`bin/rails g component Admin::Lists::Audits list`)
- Modify: books admin routes (near line 934: `resources :list_audits, only: [:index] { member { post :release } }`), `web-app/app/lib/admin/domain_nav.rb:109` (books entry "List Audits", icon `:list`, after "Enrichment Queues"), `web-app/app/components/admin/lists/show_component.html.erb` (books only: Copy audit prompt button `data-testid="copy-list-audit-prompt"` beside the Research Prompt button, and render `AuditsComponent`), `web-app/app/controllers/admin/books/lists_controller.rb` + `lists_base_controller.rb` (books-only `audit` filter param and a "Last audit" column via the existing extension hooks; add a hook if none fits)
- Test: `web-app/test/controllers/admin/books/list_audits_controller_test.rb`, `web-app/test/components/admin/lists/audits_component_test.rb`, `web-app/test/controllers/admin/books/lists_controller_test.rb`, E2E `web-app/e2e/tests/books/admin/list-audits.spec.ts`

**Interfaces:**
- Consumes: `Audits::Counts`, `Audits::Release.call(admin: true)`, `AgentPrompts.for_list_audit`.
- Queue page: four stats from `Counts.call`; Copy prompt (`data-testid="copy-agent-prompt"`, same clipboard-copy markup as `admin/books/series/index.html.erb:7-13`); table of the 50 most recent audits (list name linking to the admin list, user, status, verdict, finished_at, number of changed fields); in-progress rows show a Release button (`button_to`, write role required via `require_domain_write!`).
- Audits component: each audit with verdict badge, user, dates, note (`whitespace-pre-line`, `[overflow-wrap:anywhere]`), sources as links (`rel="noopener nofollow"`, `target="_blank"`), and the changes as a small table (field, from, to; attached/detached penalties). An open audit shows a Release button.
- [ ] **Step 1: Write the failing tests:** index 200 for a books admin, 403/redirect for a non-admin (follow the series controller test's pattern); release by an admin releases another user's audit and redirects; a viewer (read-only role) cannot release; lists index `audit=verified` filter returns the audited fixture list only; component renders a verified audit's source link and a changed field name. E2E: queue page Copy prompt puts text containing `/api/mcp/admin` and `start_list_audit` on the clipboard; on the first books list's admin page, the Copy audit prompt contains `start_list_audit` and that list's name (pattern: `series-copy-prompt.spec.ts`).
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.** No removed daisyUI v4 classes (`test/lint/daisyui_v4_classes_test.rb`).
- [ ] **Step 4: Run, expect PASS** — `bin/rails test test/controllers/admin test/components test/lint`; `yarn build:all`; confirm port 3000 is this worktree's (AGENTS.md snippet) before `yarn test:e2e e2e/tests/books/admin/list-audits.spec.ts`. If port 3000 belongs to another checkout, stop and tell Shane.
- [ ] **Step 5: Commit** — `git commit -m "Admin: list audit queue page, per-list audit prompt and history"`

### Task 10: Docs, launch todo, full verification

**Files:**
- Create: `docs/features/list-audits.md` (what it is, the tools, the queue rule "audited once", the guidance column, the two rake tasks, manual weight refresh)
- Modify: `docs/features/mcp-server.md` (tool lists, counts), `docs/features/rankings.md` (guidance vs description; null curves mean no penalty), `docs/launch-todo.md` (new section: run `bin/rails penalties:load_guidance` in production after deploy; run `bin/rails penalties:detach_dynamic` then `APPLY=1`; then work the list audit queue and refresh the books primary configuration afterwards)
- [ ] **Step 1:** Write the docs (Technical Writer conventions: no per-class doc files).
- [ ] **Step 2:** `bin/rails test` → 0 failures, no new warning lines; `bundle exec standardrb` clean; `CI=1 bin/rails zeitwerk:check` clean.
- [ ] **Step 3: Commit** — `git commit -m "Docs: list audits, penalty guidance, launch steps"`

---

## Appendix A: draft penalty guidance (for Shane to review before Task 1 loads it)

Ids and names are from the dev database (a production restore, 2026-11-21). Values in brackets are the penalty's value on the books primary configuration today; "none" means it costs nothing there. The executor copies each `name` exactly from the DB.

**Global, static**
- **1** Creator of the list sells the items [30] — The organisation that published the list sells the books on it: a bookseller (Amazon, Barnes & Noble, Waterstones, a bookshop), a publisher ranking its own titles, a book club ranking its picks. A newspaper or magazine that only carries affiliate links does not count.
- **2** Contains over 500 items [10] — The source list has more than 500 entries. Count the source, not how many we imported.
- **3** Criteria is not just best/favourite [40] — The list ranks by something other than quality or love: most influential, most important, most read, best-selling, most challenged, most underrated, "books that changed the world". "Essential", "must-read" and "greatest" count as best and do not take this. Prefer 7 when the angle is a gimmick.
- **4** Follow-up/honorable mention [50] — The list is the overflow or sequel of another list ("100 more", "honourable mentions", "the ones that didn't make the cut").
- **5** Only covers 1 specific gender [50] — Only books by authors of one gender were eligible ("best books by women"). A result that merely skews one way does not count.
- **6** Only covers 1 specific language [20] — Eligibility is limited to books originally written in one language ("best Spanish-language novels", "best novels in English"). An English-language outlet whose picks happen to be mostly English does not count.
- **7** Weird criteria [60] — The selection is built around a concept unrelated to quality (books with dogs in them, best first lines, books set on trains, cover colours). Ordinary alternative criteria such as influence take 3 instead.
- **8** Voters mostly from a single country/location [5] — Most of the people who chose the books live in one country: a national newspaper's critics, one country's readers' poll. Not for a genuinely international panel. Most single-outlet lists take this.
- **9** Diversity of voters is very low [10] — The panel comes from one narrow pool (one university's faculty, one magazine's staff, one MFA programme, one prize jury's alumni). Being from one country alone is 8, not 9.
- **10** Not critics, authors, or experts [60] — The general public chose the books (reader polls, public votes, Goodreads-style voting) with no expert vetting. If experts chose the candidates and the public ranked them, use 44. If roughly half the panel were experts, use 32.
- **11** Voters restricted to a distinct criteria [20] — Who could *vote* was limited to one group (only women critics, only Black writers, only teenagers). Restrictions on which *books* were eligible are 5 or 6, not 11.

**Global, dynamic (never attach; set the field)**
- **12** Unknown Names [5] — Set `voter_names_unknown: true` when the source does not say who chose the books. False when the panel is named, even partly.
- **13** Voter Count [up to 85] — Set `number_of_voters` to the number of people who chose the books, counted conservatively. 1 for a single critic. At 1 the penalty is the maximum; it shrinks to 0 at the configuration's median (24 today). Null means no penalty from this curve, so never leave it null when a count or estimate exists.
- **14** Unknown Count [85] — Set `voter_count_unknown: true` (and leave `number_of_voters` null) only when no count can be found or reasonably estimated. It costs as much as a single voter, so an honest estimate with `voter_count_estimated` is better when the source gives enough to estimate ("our 12 editors", "a panel of critics" with a byline list).
- **15** Only covers 1 specific location [none] — Set `location_specific: true` when the list states a geographic limit on eligible books (a country, region, continent, state or city). It costs nothing itself; it exempts the list from the western-canon penalty (23) and must be paired with exactly one static geographic penalty: 42 city, 39 state, 46 small region, 37 country, 38 large region, 36 continent (the narrowest that fits), or 31 when only about half the entries are reserved for one country.
- **16** Only covers 1 specific genre [20] — Set `category_specific: true` when eligibility is one genre or form (crime, science fiction, poetry, children's books, graphic novels) or one non-fiction subject (history, science). Literary fiction as a whole, or "novels", is not a genre for this purpose.
- **17** Number of years covered [up to 50] — Set `num_years_covered` to the span of publication years that were eligible: 1 for a yearly award or "best of 2023", 10 for a decade, 25 for "the 21st century so far" (count to the list's year), 100 for a century. Leave it null for an all-time list; null means no time penalty.
- **18** Estimated Count [none] — Set `voter_count_estimated: true` whenever `number_of_voters` is your estimate rather than a published figure.

**Books, dynamic (never attach)**
- **23** Mostly "Western Canon" books [10] — Computed from the list's books when the list is not `location_specific`: a list that presents itself as general but is 90% or more western takes it. Nothing to set; it explains why `location_specific` matters.

**Books, static**
- **21** Specific voter details are lacking [none] — The voters are named but we can learn little about who they are or why they are qualified.
- **22** Voters seem to have an agenda/bias [10] — The people choosing are promoting a viewpoint (a religious, political or advocacy organisation's list) rather than judging quality.
- **25** Favourite book per year [20] — One book was chosen for each year ("the best book of every year since 1900").
- **26** Focus on a specific theme but not definite [40] — The list is organised around a theme (religion, politics, war, nature, food) that is broader than a genre. A single genre is the `category_specific` flag instead.
- **27** Only covers genre fiction (multiple genres) [20] — Eligibility is limited to genre fiction across several genres (science fiction, fantasy and horror together). For one genre, use the `category_specific` flag alone. *(Today the 2 lists carrying 27 also have the flag; Shane: keep or drop that pairing?)*
- **31** Only partially covers 1 specific country [10] — About half the entries had to come from one country (a quota), so the field was partly reserved. Pair with `location_specific`.
- **32** Half the voters are not critics, authors, or experts [30] — Roughly half the panel were experts and half general readers.
- **34** Very hard to find any official information [50] — After a real search we could not find who made the list or how. Usually goes with an `unverifiable` audit verdict.
- **36** Only covers 1 specific continent [10] — Eligible books come from one continent ("best African novels"). Pair with `location_specific`.
- **37** Only covers 1 specific country [20] — Eligible books or authors come from one country ("best Australian novels"). Pair with `location_specific`.
- **38** Only covers 1 large geographical region [15] — One large region spanning several countries (Asia, Latin America, the Middle East, Scandinavia). Pair with `location_specific`.
- **39** Only covers 1 specific state of a country [40] — One state or province ("best Texas books"). Pair with `location_specific`.
- **42** Only covers 1 specific city [70] — One city ("best New York novels", "books set in London"). Pair with `location_specific`.
- **43** Only covers translated or foreign books [10] — Eligibility is limited to translated books, or books from outside the voters' country ("best translated fiction", the International Booker).
- **44** Public voted, but experts curated [30] — The public voted, but from a shortlist that critics, editors or experts chose.
- **45** Aggregation of other lists [40] — The list is compiled from other lists or polls, some of which we may already count, so it risks counting the same opinions twice.
- **46** Only covers 1 small geographical region [30] — A region smaller than a country or spanning parts of one (the American South, the Pacific Northwest, the Highlands). Pair with `location_specific`.
- **47** Only covers series [10] — Only books in a series were eligible.
- **49** Podcast/etc that covers 1 book a week/month [20] — A podcast, column or club featuring one book at a time; the picks are discussion topics, not a ranking.

**Not loaded:** `creator_specific` has no penalty row on books, so setting the flag does nothing today (the prompt says so).
