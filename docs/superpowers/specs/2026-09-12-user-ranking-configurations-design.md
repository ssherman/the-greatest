# User-owned ranking configurations — design

**Date:** 2026-09-12
**Status:** approved design, awaiting implementation plan
**Domain:** books first; the core is domain-generic and music/games switch on later (§14)

## 1. What this is

Signed-in users create their own ranking configuration: name it, describe it, choose
whether to share it by link, tune the six algorithm settings, switch each penalty on or
off and set its value, choose which lists feed it, and see the result on the existing
public `/rc/<id>` pages. Weights and rankings are recalculated in the background, on
creation and on demand, with a per-user daily cap and a hard "one run at a time per
configuration" lock.

This was the most requested feature on the legacy books site, which never had it.
`docs/todo.md` already lists "custom user ranking configurations (paid feature)"; the
`ranking_configurations` table has carried `user_id`, `global`, `inherited_from_id` and
`inherit_penalties` since its first migration, and `User has_many :ranking_configurations,
dependent: :destroy` already exists. None of it is wired to any controller today.

### Non-goals

- No directory or discovery of other people's configurations; a shared one is reachable
  only by its link.
- No membership gate yet. `RankingConfigurationPolicy#create?` is the single place it goes
  later (§7).
- No music/games UI in this delivery (§14 lists exactly what switching them on takes).
- No custom penalties. Users toggle and value the catalogue penalties; they never author
  `Penalty` rows.
- No per-run history table. Status lives on the configuration row.

## 2. Decisions

| # | Decision |
|---|---|
| 1 | **Max 5 configurations per user per configuration type** (`RankingConfiguration::MAX_PER_USER`). |
| 2 | **Max 5 manual refreshes per user per rolling 24 h** via Rails 8 `rate_limit` on the shared Redis store. The automatic run on create does not count. A refresh request made while a run is in progress is rejected *before* the rate limit runs, so it does not burn one of the 5. |
| 3 | **Bounds.** Model-wide: `max_list_dates_penalty_age <= 200` (was unbounded). User-owned only: `min_list_weight` 0..100 (the books primary carries −50 and must stay valid), `description` ≤ 1000 chars. `primary: true` is forbidden on a user-owned configuration model-wide (today nothing stops it, and `ensure_only_one_primary_per_type` would silently demote the real primary). |
| 4 | **A disabled penalty is the absence of a `PenaltyApplication` row.** That is how `Rankings::WeightCalculatorV1` already works (`find_by(ranking_configuration:)` then `next unless`), and how the six penalties the primary does not apply already behave. |
| 5 | **User-owned configurations are never edge-cached.** Every page under `/rc/` for one is `no-store, private`. A private one 404s for anyone but its owner. Purge-on-unshare is not needed because nothing was cached. |
| 6 | **Banner** on every `/rc/` page for a user-owned configuration only (not the global year configurations): *"You're viewing a custom ranking: ‹name›. See the official rankings →"*. No owner name. |
| 7 | **New Sidekiq queue `low`**, appended to `config/sidekiq.yml`. Strict priority, so it drains only when `critical` and `default` are empty. Production runs `bundle exec sidekiq` with no `-C`, and Sidekiq auto-loads `config/sidekiq.yml`, so the queue reaches production without a deploy-config change. Shane plans a Sidekiq-only server; this queue is where that work lands. |
| 8 | **Delete is supported** and is plain `destroy`; the existing `dependent: :destroy` on `ranked_items`, `ranked_lists` and `penalty_applications` cascades. |
| 9 | **Column name `user_shared`**, not `public`: on the shared table `public: false` on the primary reads as if the primary were private. |
| 10 | **Starting point is the user's choice**: copy the official configuration (default) or start from scratch (§8.2). |
| 11 | **Books only now, nothing books-specific.** Global routes resolved from `Current.domain` (the saved-searches shape), a registry with one entry, shared views. |
| 12 | **Services only where a write spans tables**: `Create`, `Save`, `AddLists`. Refresh is a model method. Delete and remove-a-list are controller code. |

## 3. Current state (what the design builds on)

- `RankingConfiguration` is STI (`Books::RankingConfiguration`, `Music::Albums::…`,
  `Music::Songs::…`, `Games::…`; `Books::Authors::…`/`Music::Artists::…` are derived and
  not user-creatable). `default_primary` = `global.primary.first`.
- The books primary (dev DB, a prod restore): 623 ranked lists of 758 active, 21,392
  ranked items, 41 penalty applications out of 47 books-applicable penalties,
  `min_list_weight = -50` (already floored to 0 by `weight_floor`).
- Weights: `Rankings::BulkWeightCalculator` (per-list `WeightCalculatorV1`, penalties read
  through `PenaltyApplication.value`). Rankings: `RankingConfiguration#calculate_rankings`
  → `ItemRankings::<Domain>::Calculator`, which consumes `exponent`,
  `bonus_pool_percentage`, `apply_list_dates_penalty`, `max_list_dates_penalty_age`,
  `max_list_dates_penalty_percentage`; `min_list_weight` is consumed by the weight
  calculator via `weight_floor`. Nothing chains the two steps today; both jobs run on
  `default`; nothing records status on the row.
- `CalculateRankingsJob` enqueues `Books::CalculateAuthorRankingsJob` for **every** books
  configuration; only the reindex is gated on `default_primary?`.
- `/rc/:id` is resolved in six places, each a bare `RankingConfiguration.find`:
  `ApplicationController#load_ranking_configuration` (11 controllers),
  `RankedItemsController#find_ranking_configuration` (books, music albums, music songs),
  `Games::RankedItemsController#find_ranking_configuration` (override),
  `Books::FiltersController#find_ranking_configuration` (override, always `prevent_caching`),
  and `Books::BrowseController` / `Books::GlobalCanonController`, which hardcode the primary
  and never read the param. Every public cache header is set through
  `Cacheable#cache_for_index_page` / `#cache_for_show_page` (30 call sites, including
  `PublicListsController#apply_caching`), and in every controller the configuration is
  loaded before the cache header is set.
- Search indexing is already scoped away from non-primary configurations:
  `Books::Book#primary_ranked_item` is hard-scoped to `default_primary`, and
  `Books::ReindexRankedFieldsJob` loads the primary itself. Nothing to add; §10 pins it
  with a test.
- Public layouts render no flash. The toast region is client-dispatched only.
- Precedents copied: `Books::My::ReadingGoalsController` + `Books::ReadingGoalPolicy`
  (owner CRUD, 404-not-403), `SavedSearchesController` + `SavedSearchDomainScoped` +
  `DomainLayout` (global routes, `Current.domain`), `ContactMessagesController`
  (`rate_limit`), `Admin::RankedListsController` (Turbo-Frame list management with
  in-frame pagination), `saved_search_picker_controller.js` (debounced search → chips),
  `Admin::DomainRouting` (registry of lambdas), `Actions::Admin::CreateNextYearConfiguration`
  (save the parent, then build penalty applications — `clone_for_inheritance` builds
  children before the parent has an id and is not used).

## 4. Data model

One migration on `ranking_configurations` (small table; metadata-only `ADD COLUMN`s):

```ruby
add_column :ranking_configurations, :user_shared,          :boolean,  null: false, default: false
add_column :ranking_configurations, :refresh_status,       :integer,  null: false, default: 0
add_column :ranking_configurations, :needs_refresh,        :boolean,  null: false, default: false
add_column :ranking_configurations, :refresh_requested_at, :datetime
add_column :ranking_configurations, :last_refreshed_at,    :datetime
add_column :ranking_configurations, :last_refresh_error,   :text
```

No new indexes: a user has at most 5 rows per type and
`index_ranking_configurations_on_type_and_user_id` already exists.

Model (`app/models/ranking_configuration.rb`), every addition inert for global rows:

```ruby
MAX_PER_USER = 5
REFRESH_STALE_AFTER = 1.hour

enum :refresh_status, {idle: 0, queued: 1, running: 2, failed: 3}, prefix: :refresh

def user_owned? = !global?

# Existing rule tightened model-wide.
validates :max_list_dates_penalty_age,
  numericality: {only_integer: true, greater_than: 0, less_than_or_equal_to: 200}, allow_nil: true

# User-owned only. The books primary stores -50 and must stay valid.
validates :min_list_weight,
  numericality: {only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100},
  if: :user_owned?
validates :description, length: {maximum: 1000}, if: :user_owned?
validate :user_owned_cannot_be_primary, if: :primary?
validate :user_owned_within_limit, on: :create, if: :user_owned?

# Atomic compare-and-swap. Two simultaneous callers serialize on the row lock and the
# loser re-evaluates the WHERE against the winner's committed value, so at most one
# caller ever sees 1. The stale clause reclaims a row wedged by a worker killed
# mid-run (OOM, SIGKILL), which no rescue can catch.
def request_refresh!
  claimed = self.class.where(id: id)
    .where("refresh_status IN (:free) OR refresh_requested_at < :stale",
      free: [self.class.refresh_statuses[:idle], self.class.refresh_statuses[:failed]],
      stale: REFRESH_STALE_AFTER.ago)
    .update_all(refresh_status: self.class.refresh_statuses[:queued],
      refresh_requested_at: Time.current, last_refresh_error: nil)
  return false unless claimed == 1

  RankingConfigurations::RefreshJob.perform_async(id)
  true
end

def refresh_in_progress? = refresh_queued? || refresh_running?
```

`user_owned_within_limit` counts `self.class.where(user_id:, type:)` — 5 per user **per
type**, so a future music user gets 5 album and 5 song configurations.

`User#ranking_configurations` already exists with `dependent: :destroy`; no change.

## 5. Registry — `app/lib/ranking_configurations/registry.rb`

All domain knowledge this feature needs, in one place; adding a domain is adding entries.

```ruby
module RankingConfigurations
  module Registry
    URL_HELPERS = Rails.application.routes.url_helpers

    Entry = Struct.new(
      :domain,                        # :books
      :kind,                          # "books" — the URL/param token; music will have "albums"/"songs"
      :ranking_configuration_class,   # "Books::RankingConfiguration"
      :list_class,                    # "Books::List" — what the picker searches and AddLists accepts
      :penalty_classes,               # ["Global::Penalty", "Books::Penalty"]
      :results_path,                  # ->(config) { URL_HELPERS.books_rc_path(ranking_configuration_id: config.id) }
      :lists_path,                    # ->(config) { URL_HELPERS.books_rc_lists_path(ranking_configuration_id: config.id) }
      :official_rankings_path,        # -> { URL_HELPERS.books_root_path }
      keyword_init: true
    )

    ENTRIES = [
      Entry.new(
        domain: :books, kind: "books",
        ranking_configuration_class: "Books::RankingConfiguration",
        list_class: "Books::List",
        penalty_classes: ["Global::Penalty", "Books::Penalty"],
        results_path: ->(config) { URL_HELPERS.books_rc_path(ranking_configuration_id: config.id) },
        lists_path: ->(config) { URL_HELPERS.books_rc_lists_path(ranking_configuration_id: config.id) },
        official_rankings_path: -> { URL_HELPERS.books_root_path }
      )
    ].freeze

    def self.for_domain(domain)  = ENTRIES.select { |e| e.domain == domain.to_sym }
    def self.find(domain, kind)   = for_domain(domain).find { |e| e.kind == kind.to_s }
    def self.for_config(config)   = ENTRIES.find { |e| e.ranking_configuration_class == config.type }
  end
end
```

- `for_domain(Current.domain).empty?` → the whole `/my/rankings` surface 404s
  (`require_domain_support!`, the `SavedSearchDomainScoped` pattern). Because one Firebase
  project serves every domain, a music or games user can sign in and type the URL today;
  the empty registry is what keeps it closed until that domain is switched on.
- `kind` is only consulted by `new`/`create`. With one entry per domain (books, games) the
  form never shows a chooser; with more than one (music) `new` renders a kind chooser
  first. Every later action resolves its entry from the record's STI `type`.
- Copy that names the medium uses the existing `media_noun_plural` ("books"), never a
  literal.

## 6. Services and model methods

`app/lib/services/ranking_configurations/`, each with
`Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.

### `Create.call(user:, entry:, attributes:, penalties:, start:, seed_lists:)`

`start` is `:official` or `:scratch`; `seed_lists` is only honoured for `:official`.
One transaction:

1. Build the configuration. `:official`: `entry.ranking_configuration_class.default_primary`
   (fail with a friendly error if none) `.dup`, then override `global: false`, `user`,
   `primary: false`, `published_at: nil`, `year: nil`, `list_limit: nil`, the mapped-list
   columns `nil`, `inherited_from_id: primary.id`, `min_list_weight: primary.weight_floor`,
   `refresh_status: :idle`, `needs_refresh: true`, then `assign_attributes(attributes)`.
   `:scratch`: `entry.ranking_configuration_class.new` with model defaults, `global: false`,
   `user`, `inherited_from_id: nil`, `needs_refresh: true`, then `assign_attributes(attributes)`.
2. `save!` (the 5-cap and every bound run here).
3. Penalty applications from `penalties` (§8.3 shape): one `PenaltyApplication` per enabled
   penalty whose id is in `entry.penalty_classes`' catalogue, `value` as submitted. Parent
   first, then children — the `CreateNextYearConfiguration` order.
4. If `:official` and `seed_lists`: `RankedList.insert_all` one row per
   `primary.ranked_lists.pluck(:list_id)` (one INSERT for ~623 rows; validations skipped
   deliberately — the rows come from an already-valid same-type source and the new id
   cannot collide on the unique index).
5. `transaction.after_commit { config.request_refresh! }` — the automatic first run. It
   never passes through the rate-limited action, which is how it stays exempt.

Returns `data: {ranking_configuration:}`; validation failure returns the record with its
errors so the form re-renders.

### `Save.call(config:, attributes:, penalties:)`

Edit path, one transaction: `assign_attributes` + `save!`; then for each catalogue penalty,
enabled → `penalty_applications.find_or_initialize_by(penalty:)` with the new value,
disabled → destroy the row if present. All-or-nothing: one bad value rolls the whole
update back and the form re-renders with errors. Sets `needs_refresh: true` only if any
of `exponent bonus_pool_percentage min_list_weight apply_list_dates_penalty
max_list_dates_penalty_age max_list_dates_penalty_percentage` changed or any penalty row
was added, changed or removed. Name, description and `user_shared` never mark the
configuration stale.

### `AddLists.call(config:, list_ids:)`

Filters to `entry.list_class.where(status: :active, id: list_ids)` not already in
`config.ranked_lists`, `insert_all` the survivors, `needs_refresh: true` if any were
inserted. Used by the picker's "Add selected", each diff row's Add, and "Add all N".
Returns `data: {added: n}`.

### `MissingListsQuery.call(config:)`

Read-only: the domain's **current** `default_primary`'s active ranked lists whose
`list_id` is not in `config.ranked_lists`, `includes(:list)`, ordered by weight desc.
Diffing against the live primary rather than `inherited_from` keeps it right when a new
primary is promoted, and makes it work for from-scratch configurations too.

### Model methods and plain controller code

- `RankingConfiguration#request_refresh!` (§4) — the lock and the enqueue.
- Delete: `@ranking_configuration.destroy` in the controller.
- Remove a list: `@ranking_configuration.ranked_lists.find_by!(list_id:).destroy` then
  `update!(needs_refresh: true)` in the lists controller.

## 7. Job, queue, throttle, authorization

### `RankingConfigurations::RefreshJob`

`bin/rails generate sidekiq:job ranking_configurations/refresh`;
`sidekiq_options queue: :low, retry: false`.

```
perform(id)
  config = RankingConfiguration.find_by(id:) or return      # deleted while queued: not an error
  config.update_columns(refresh_status: :running)
  Rankings::BulkWeightCalculator.new(config).call            # weights, in-process
  result = config.calculate_rankings                         # rankings, in-process
  raise result.errors.join(", ") unless result.success?
  config.update_columns(refresh_status: :idle, needs_refresh: false,
                        last_refreshed_at: now, last_refresh_error: nil)
rescue => e
  update_columns(refresh_status: :failed, last_refresh_error: e.message.truncate(500))
  (do not re-raise: the status column is the failure surface)
```

- One job, one lifecycle. Two chained jobs would add a "crashed between them" state and
  a second class whose only role is bookkeeping.
- `retry: false`: the status column and the Refresh button are the retry UX. Sidekiq
  retries would rerun invisibly, fight the lock, and spend the user's cap without them
  knowing.
- Calls the calculators directly rather than `CalculateRankingsJob.new.perform` so the
  primary-only side effects never enter the picture. `BulkWeightCalculator` swallows
  per-list errors into `results[:errors]`; the job treats a non-empty `errors` array as a
  failure.
- `config/sidekiq.yml`: append `- low`. The queue shares the 5-thread pool and gets
  lowest priority; a busy `default` delays user refreshes, which is the intended trade.

### `CalculateRankingsJob` fix

Gate `Books::CalculateAuthorRankingsJob` on `default_primary?` alongside the existing
reindex gate. Without it every user refresh would recompute global author rankings. The
refresh job above does not go through `CalculateRankingsJob`, but the admin path still
does, and the year configurations hit the same bug today.

### Throttle

In `My::RankingConfigurationsController`, in this order:

```ruby
before_action :require_signed_in!
before_action :set_ranking_configuration, only: [...]
before_action :reject_refresh_in_progress, only: :refresh   # cheap read; runs BEFORE the counter
rate_limit to: 5, within: 24.hours,
  by: -> { current_user.id },
  with: -> { render_refresh_limited },
  store: Rails.application.config.x.rate_limit_store,
  name: "ranking-configuration-refresh",
  only: :refresh
```

`refresh` then calls `request_refresh!`; a `false` (lost the race) renders the same
"already running" response as the pre-check. Tests clear the store in `setup` as the
house convention already does.

### Policy — `app/policies/ranking_configuration_policy.rb`

Owner-based, separate from the admin `Books::RankingConfigurationPolicy` (domain roles,
bulk actions). `index?/create?/new?` = signed in; `show?/edit?/update?/destroy?/refresh?/
manage_lists?` = owner; `Scope#resolve` = `scope.where(user:)` or `none`. **Every
`authorize` passes `policy_class: RankingConfigurationPolicy`**: Pundit's default for a
`Books::RankingConfiguration` record is the admin policy, and omitting it once would
authorize a stranger with a domain role. A policy test asserts a domain editor who is not
the owner is denied. `create?` is where the membership gate goes later.

Public `/rc/` visibility (§9) is a plain model check, not Pundit — it must run identically
for anonymous visitors.

## 8. Routes, controllers, pages

### Routes (global block next to `/searches`; no `DomainConstraint`)

```
GET    /my/rankings                          my/ranking_configurations#index
GET    /my/rankings/new                      #new        (?start=scratch, ?kind= for multi-kind domains)
POST   /my/rankings                          #create
GET    /my/rankings/:id                      #show       (manage page)
GET    /my/rankings/:id/edit                 #edit
PATCH  /my/rankings/:id                      #update
DELETE /my/rankings/:id                      #destroy
POST   /my/rankings/:id/refresh              #refresh
GET    /my/rankings/:id/state                #state      (JSON, polled while a run is in progress)
GET    /my/rankings/:id/lists                my/ranking_configurations/lists#index
GET    /my/rankings/:id/lists/search         #search     (JSON [{value, text}])
POST   /my/rankings/:id/lists                #create     (list_ids[])
POST   /my/rankings/:id/lists/add_missing    #add_missing
DELETE /my/rankings/:id/lists/:list_id       #destroy
```

`new` before `:id`; every `:id`/`:list_id` constrained to `/\d+/`. The shareable link is
`entry.results_path(config)`, i.e. `/rc/<id>` on the books host.

### Controllers

`My::RankingConfigurationsController` and `My::RankingConfigurations::ListsController`
(generators; `app/controllers/my/…`). Both: `include Cacheable, DomainLayout,
RankingConfigurationOwnerScoped` (a small concern named after `SavedSearchDomainScoped`:
`require_domain_support!`, `set_ranking_configuration` =
`current_user.ranking_configurations.find(params[...])` + `authorize … policy_class:`,
`current_entry`), `layout :resolve_layout`,
`before_action :prevent_caching`, `before_action :require_signed_in!`. Cross-user access
is a 404 through the scoped `find`, never a 403.

Feedback: a `my/ranking_configurations/_notice.html.erb` partial rendered inside these
views shows `flash[:notice]`/`flash[:alert]` as DaisyUI alerts; the layouts render no
flash. Turbo Stream responses re-render the same partial inside the frame.

### 8.1 Index — `/my/rankings`

Your configurations for this domain (≤ 5): name, Shared/Private badge, status badge
(Calculating / Needs refresh / Up to date / Failed), last refreshed, links to Manage and
View rankings. "New ranking" button, disabled with "You've reached the limit of 5
rankings." at the cap.

### 8.2 New and Edit — one form, four sections

`new` pre-fills from the official configuration. A line at the top reads *"Starting from
the official rankings — or start from scratch"*; the link goes to `new?start=scratch`,
which pre-fills model defaults, every penalty off, and no lists (server-rendered; no JS).
A hidden `start` field carries the choice into `create`.

1. **Details** — name (required, ≤ 255), description (≤ 1000, plain text), "Share via
   link" checkbox with help *"Anyone with the link can view this ranking. Private rankings
   are visible only to you."* On edit, the share link in a read-only input labelled
   "Share link" when shared.
2. **Settings** — the six fields with plain-language explainers and HTML `min/max/step`
   matching the validations; the two recency fields stay visible with help text saying
   they only apply while the toggle is on (no JS — `conditional_field_controller.js` only
   toggles on a `<select>`). Copy uses `media_noun_plural`:
   - *Position bonus curve (exponent)*, 0.01–10, step 0.01 — "How much more a #1 placement
     is worth than a low one. Higher values reward top spots more steeply. The official
     rankings use 3."
   - *Bonus pool (%)*, 0–100 — "The share of each list's weight set aside as a bonus for
     higher positions. At 0, position on a list doesn't matter. The official rankings use 3."
   - *Lowest possible weight*, 0–100 — "No list can fall below this weight no matter how
     many penalties apply. The official rankings use 0."
   - *Recency adjustment* (toggle) — "Reduce the credit a list gives to ‹books› published
     shortly before the list came out. Classics are unaffected."
   - *Maximum recency reduction (%)*, 1–100 — "How much a placement is reduced when the
     list and the ‹book› share a year. The official rankings use 80."
   - *Recency reduction fades out after (years)*, 1–200 — "The reduction shrinks as the gap
     grows and disappears at this many years. The official rankings use 50."
3. **Penalties** — every penalty in `entry.penalty_classes` with `user_id: nil`, grouped
   under the existing `Penalty.category_title` headings, each row: checkbox, name,
   description, value 0–100. Dynamic penalties carry an "applied automatically" note (the
   value is their maximum). Defaults: official value and on for penalties the official
   configuration applies, off otherwise; on edit, the configuration's own rows.
4. **Lists** (new, official start only) — "Start with the 623 lists from the official
   rankings" checkbox, default on, with *"You can add and remove lists after creating."*

Validation failure re-renders with inline, `aria-describedby`-linked errors in the
reading-goals markup (`fieldset`/`fieldset-legend`, bare `input`, `input-error`).

### 8.3 Penalty parameter shape

`penalties[<penalty_id>][enabled]` (checkbox) and `penalties[<penalty_id>][value]`.
`Create`/`Save` iterate the catalogue, not the params, so an unknown or foreign id is
ignored and a missing key means off.

### 8.4 Show — `/my/rankings/:id` (manage)

- Header: name, description, Shared/Private badge, share link when shared.
- **Status panel** (`data-controller="ranking-configuration-status"`):
  - queued/running: *"Calculating weights and rankings. This usually takes a few minutes —
    this page will update when it's done."* Refresh button rendered disabled. (When the
    button is active it carries `data-turbo-submits-with="Starting…"` for the in-flight
    click; the server lock remains the authority.)
  - idle + needs_refresh: *"Your changes haven't been applied yet."* + **Refresh weights
    and rankings** button.
  - idle: *"Up to date. Last refreshed ‹time ago›."* + the button.
  - failed: *"The last refresh failed: ‹error›. You can try again."* + the button.
  - After a rejected refresh: *"A refresh is already running for this ranking."* or
    *"You've used all 5 refreshes for today. Try again later."*
- Settings summary (the six values) with Edit; penalties count ("31 of 47 penalties on")
  with Edit; lists count with Manage lists; **View rankings** (`entry.results_path`, opens
  the public page); Delete with `turbo_confirm`.
- The Stimulus controller polls `/state` every 5 s while `data-…-active-value` is true and
  `Turbo.visit(location.href, {action: "replace"})` once the status leaves queued/running.
  `disconnect()` clears the timer. `/state` returns
  `{refresh_status, needs_refresh, last_refreshed_at, last_refresh_error}`.

### 8.5 Lists — `/my/rankings/:id/lists`

Full page whose body is `turbo_frame_tag "rc_lists", target: "_top"` (off-page links —
list names → the public list page — escape the frame; forms opt back in with
`data: {turbo_frame: "rc_lists"}`, pagination with
`series_nav(anchor_string: 'data-turbo-frame="rc_lists"')`). Inside:

1. **Add lists** — search box (`data-controller="saved-search-picker"`, unchanged JS,
   `url-value` = the search route, `name-value="list_ids[]"`, `aria-label="Search lists"`),
   chips, "Add selected lists" submit → `POST lists`. The search endpoint returns
   `entry.list_class.where(status: :active).search_text(q)` minus lists already present,
   limit 10, `{value: id, text: "‹name› (‹source›, ‹year›)"}`.
2. **In the official rankings but not in yours (N)** — `MissingListsQuery` rows: name,
   source/year, weight in the official ranking, an Add button (`POST lists` with one id);
   "Add all N" → `POST add_missing`. Hidden when N = 0 ("Your ranking includes every
   official list.").
3. **Your lists (N)** — 50 per page, path-based: name (link, `target: "_top"`), source/year,
   weight (or "not yet calculated"), Remove (`DELETE`, `turbo_confirm`). Every
   ranked-list row `includes(:list)`; the page is pinned with `assert_queries_count`.

`create`/`add_missing`/`destroy` respond with a Turbo Stream that replaces `rc_lists`
with the re-rendered frame (current `page` carried in a hidden field) and a notice line
inside it ("Added 3 lists. Refresh weights and rankings to apply."). The frame also
carries a compact status line with the Refresh button so users don't have to go back to
the manage page; that button's form is deliberately **not** opted into the frame, so its
`POST /refresh` navigates the whole page to the manage page, where the status panel and
polling live.

### 8.6 Nav

"My Rankings" added to both `#navbar_my_books` lists in
`app/views/books/shared/_nav_links.html.erb`, next to Reading Goals.

## 9. `/rc/:id` — visibility, no-cache, banner

Three shared mechanisms; no per-page wiring.

1. **`RankingConfigurationGating`** concern, included in `ApplicationController`:

   ```ruby
   def gate_ranking_configuration!(config)
     return if config.nil? || config.global?
     unless config.user_shared? || config.user_id == current_user&.id
       raise ActiveRecord::RecordNotFound
     end
     @custom_ranking_configuration = config
   end
   ```

   Called at the end of `ApplicationController#load_ranking_configuration`,
   `RankedItemsController#find_ranking_configuration`,
   `Games::RankedItemsController#find_ranking_configuration` and
   `Books::FiltersController#find_ranking_configuration`. Global configurations never touch
   the session, so cached global pages stay session-free.

2. **`Cacheable`**: `cache_for_index_page` and `cache_for_show_page` each begin with
   `return prevent_caching if @ranking_configuration&.user_owned?`. This covers all 30
   call sites, `PublicListsController#apply_caching` included, and in every one the
   configuration is loaded before the header is set (verified for the books controllers;
   the regression tests below make that an invariant rather than an observation).

3. **Banner**: `app/views/shared/_custom_ranking_banner.html.erb`, rendered by
   `layouts/books/application.html.erb` at the top of the content area when
   `@custom_ranking_configuration` is set. Name only; the link is
   `Registry.for_config(config).official_rankings_path.call`. Music and games layouts get
   the same line when they are switched on.

Regression tests, one per books controller that resolves `/rc/`: a global configuration
still returns `Cache-Control: public` with no banner; a shared user configuration returns
200, `no-store`, and the banner, for an anonymous visitor; a private one 404s for a
stranger and for anonymous and 200s for the owner.

## 10. Search indexing

Nothing to add. `Books::Book#primary_ranked_item` is scoped to `default_primary`, the
reindex job loads the primary, and the refresh job never enqueues a reindex. Two tests pin
it: a user configuration's `RankedItem` does not change a book's `as_indexed_json`
`ranked_position`, and `CalculateRankingsJob` on a non-primary books configuration enqueues
neither the reindex nor the author-rankings job.

## 11. Validation summary

| Field | Rule | Scope |
|---|---|---|
| `name` | present, ≤ 255 | existing |
| `description` | ≤ 1000 | user-owned |
| `exponent` | > 0, ≤ 10 | existing |
| `bonus_pool_percentage` | 0–100 | existing |
| `min_list_weight` | integer 0–100 | user-owned (primary keeps −50) |
| `max_list_dates_penalty_age` | integer 1–200 | model-wide (was unbounded) |
| `max_list_dates_penalty_percentage` | integer 1–100 | existing |
| `primary` | must be false | user-owned |
| count per (user, type) | ≤ 5 | user-owned, on create |
| `PenaltyApplication#value` | integer 0–100 | existing |

## 12. Testing

- **Model**: each rule above; `user_owned?`; the enum; `request_refresh!` returns true
  once and false on a second call, reclaims a `running` row older than an hour, sets
  `queued` and clears the error, enqueues the job.
- **Registry**: `for_domain`, `find`, `for_config` for books; empty for a domain with no
  entry.
- **Services**: `Create` official (settings copied, `min_list_weight` clamped, penalties
  copied, 623 lists seeded, `inherited_from_id` set, job enqueued after commit), official
  without lists, scratch (defaults, no penalties, no lists, no inheritance), 5-cap, no
  primary, rollback on a child failure; `Save` (enable creates, disable destroys, one bad
  value rolls everything back, `needs_refresh` only on ranking-affecting change);
  `AddLists` (filters inactive/wrong-type/duplicate ids, `needs_refresh`);
  `MissingListsQuery` (diffs against the current primary, empty when complete).
- **Job**: success sets idle/`needs_refresh: false`/timestamp; a calculator failure or a
  weight error sets failed with the message and does not raise; a deleted configuration is
  a no-op. `CalculateRankingsJob`'s new gate.
- **Controllers**: sign-in required; 404 on every action for a non-owner; 404 for a domain
  with no registry entry; cap on create; refresh: 6th call in a window is limited, a call
  during a run is rejected without consuming the limit (assert the 5 real ones still
  succeed afterwards), lost race renders the same response; state JSON; lists: add via
  ids, add_missing, destroy, search (active lists of the right type only, excludes present
  ones), Turbo Stream responses name the frame, `assert_no_frame_trapped_links`,
  `assert_queries_count` on the lists page. Behaviour only — never markup or copy.
- **Policy**: owner-only; a domain editor who is not the owner is denied.
- **`/rc/` gating and headers**: §9's matrix for `Books::RankedItemsController`,
  `Books::ListsController` (index and show), `Books::BooksController#show`,
  `Books::AuthorsController#show`, `Books::FiltersController`.
- **Routing test** mirroring `books_reading_goals_routes_test.rb`.
- **Lint**: `test/lint/daisyui_v4_classes_test.rb` and the Stimulus lint already cover the
  new views. `CI=1 bin/rails zeitwerk:check` after adding `app/lib/ranking_configurations/`.
- **E2E** (`e2e/tests/books/account/ranking-configurations.spec.ts`, serial): a first step
  deletes any leftover configuration whose name starts with the spec's prefix (the 5-cap
  would otherwise wedge the shared E2E account after a few failed runs); then create from
  official → manage page shows Calculating → edit a setting and a penalty → lists page:
  search-add, remove, add-missing → refresh (one of the 5) → `/rc/<id>` shows the banner →
  a fresh anonymous context gets 404 on the private one and 200 on it after sharing →
  delete. Marked as not repeatable more than 5 times an hour, like `contact.spec`.

## 13. Build sequence (suite green after each)

1. Migration + model (enum, validations, `request_refresh!`) + fixtures
   (`books_user_config`, `books_user_config_shared`).
2. `RankingConfigurationGating` + `Cacheable` guard + the four resolver call sites +
   `CalculateRankingsJob` gate + §9/§10 regression tests. Landable on its own.
3. Registry (books entry) + `RefreshJob` + `low` queue.
4. `Create`, `Save`, `AddLists`, `MissingListsQuery`.
5. `RankingConfigurationPolicy`.
6. Routes + `My::RankingConfigurationsController` + index/new/edit/show views + `_notice`
   (no refresh, no lists yet).
7. `refresh`, throttle, `/state`, the status Stimulus controller.
8. `My::RankingConfigurations::ListsController` + lists page + picker wiring.
9. Banner partial + layout line + nav link.
10. E2E spec + `docs/features/user-ranking-configurations.md`.

## 14. Switching on music or games later

Per domain: registry entries (two for music — albums and songs — which exercises the kind
chooser on `new` for the first time), one nav link, one layout line for the banner, one
E2E spec under that domain's `e2e/tests/<domain>/`. No shared controller, model, job or
policy edits: the parts that run on live music/games pages today (§9's gating and cache
guard, the `CalculateRankingsJob` gate, the model validations) ship and are tested in
this delivery, before any music/games user configuration can exist.

## 15. Known trade-offs

- **`low` has no SLA.** A busy `default` queue delays user refreshes; the manage page says
  "a few minutes" and keeps polling. The Sidekiq-only server is the fix.
- **The daily cap is a fixed window** (Rails `rate_limit` semantics: 24 h from the first
  refresh), keyed by user, opaque to the UI. The user learns the cap when they hit it.
- **Concurrent runs after stale reclaim.** If a run genuinely exceeds an hour and a
  second is claimed, both write the same rows; the later one wins and nothing is
  corrupted. Accepted for a rare case.
- **Every refresh recalculates all weights.** No incremental path; the primary today is
  the same cost, once.
