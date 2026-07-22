# Books admin — increment 6b: Lists + Ranking Configurations + legacy date-penalty parity

**Status:** design approved 2026-07-22, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; increment 6,
"Categories, Lists, Ranking configurations"; decision D8).
**Predecessors:** 6a (categories + shared-controller domain-auth fix — PR #174, merged `a89fd73`).
**Split:** increment 6 shipped as 6a (categories) + **6b (this doc)**. One PR (owner call, 2026-07-22).

## Goal

The books admin's Lists and Ranking-Configuration surfaces at `new.thegreatestbooks.org/admin`, plus
the fix that makes the new books rankings actually reproduce the **legacy** TheGreatestBooks ranking
algorithm. `Books::List` (1,030 rows) and `Books::RankingConfiguration` (4 rows) are already migrated;
this is their admin surface, and the point at which "Refresh Rankings" must produce legacy-correct
output.

## Scope

**In:**
- **`Books::List` CRUD** — thin subclass of `Admin::ListsBaseController`, list items managed through the
  existing shared `Admin::ListItemsController` + a books typeahead. **No wizard** (no importer / external
  API — design D1).
- **`Books::RankingConfiguration` CRUD** — thin subclass of `Admin::RankingConfigurationsController`;
  ranked-lists / penalty-applications / ranked-items come free once the registry knows books' RC path.
- **Legacy date-penalty parity (revised D8)** — `Books::Book#release_year` + two legacy behaviors in the
  shared item-ranking calculator, so the books date penalty runs like the old site. See Part 3 — this
  **replaces** the umbrella's `calculate_books_year_range` fix, which turns out to be moot for books.
- `DomainNav` "Lists" + "Rankings" items, `DomainRouting` `LISTS` + `RANKING_CONFIGURATIONS` entries,
  Minitest coverage, and Playwright smoke specs.

**Out (deferred / not applicable):**
- **`calculate_books_year_range` (umbrella D8)** — dropped. It belongs to the per-list *temporal-coverage*
  penalty (`dynamic_type: :num_years_covered`), which **no books RC applies**, so the stub is dead code
  for books and the legacy app has no year-range concept at all (Part 3). Left untouched.
- **Viewer-can-write hardening** of the shared `ranked_lists` / `penalty_applications` / `list_items` /
  `list_penalties` controllers — its own follow-up PR (owner call). 6b's registry-path addition grants
  books domain users **read** access to these (the denial-test flips below are reads); it does **not**
  introduce any new viewer-*write* path beyond the pre-existing cross-domain gap. Tracked separately.
- No list wizard, no external books API/importer (D1). Inc 7 (full Playwright suite) stays separate.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 6b-1 | One PR (lists + RC + date-penalty parity). | Coupled: the RC admin's "Refresh Rankings" is only correct once the date-penalty parity fix lands. Owner call. |
| 6b-2 | Books lists have **no wizard**; guard the shared `Admin::Lists::ShowComponent` "Launch Wizard" button on the wizard path being present, and books' `wizard_path` returns `nil`. | The base controller *requires* a `wizard_path` hook, and the ShowComponent renders the button unconditionally today. Making the button conditional is a one-line, behavior-neutral improvement (music/games return real paths) — cleaner than a bespoke books show view. |
| 6b-3 | Books RC needs **zero** new views. | The base `RankingConfigurationsController` renders the shared `app/views/admin/ranking_configurations/*`, resolved by controller inheritance; games' RC subclass has no own views either. |
| 6b-4 | Register `Books::RankingConfiguration`'s `path:` — accept that this flips the shared `ranked_lists` / `penalty_applications` books-denial tests to *allowed*. | The `path:` is load-bearing for auth (`domain_with_ranking_configuration_admin_for`). The flips are **read** access for books domain users and are the intended effect (inc-3 landmine). |
| 6b-5 | **Drop** the `calculate_books_year_range` fix; do the `release_year` + legacy-parity fix instead. | Investigation (below) shows the year-range function is never called for books, and the real gap is that `Books::Book` lacks `release_year`, silently disabling the legacy recency penalty the primary RC is configured to apply. |
| 6b-6 | The two legacy edge cases (nil publication year → max penalty; yearly-award list → max penalty) go in the **shared** `ItemRankings::Calculator`, not a books override. | Owner: these are general ranking rules, "just not implemented yet" for music/games. `yearly_award` is inert there (0 award lists); the nil-year change re-ranks ~1% of music/games items — an accepted correctness fix, folded into 6b. |

## Part 1 — Books Lists

### Model (exists — no schema change)
`Books::List < List` (STI on `lists`): `name`, `status` enum, `year_published` (765/1,030 populated),
`yearly_award` (boolean; **50 books lists are award lists**), `wizard_state` (jsonb, unused for books),
`simplified_content`, etc. `list_items` are polymorphic (`listable: Books::Book`), all 65,252 linked.

### Controller
`Admin::Books::ListsController < Admin::ListsBaseController` + `include Admin::DomainScopedAuth`, mirroring
`Admin::Games::ListsController` **minus the wizard**:

```ruby
def policy_class   = ::Books::ListPolicy
def item_label     = "Book"
def list_class     = ::Books::List
def lists_path     = admin_books_lists_path
def list_path(l)   = admin_books_list_path(l)
def new_list_path  = new_admin_books_list_path
def edit_list_path(l) = edit_admin_books_list_path(l)
def param_key      = :books_list
def items_count_name = "books_count"
def listable_includes = [:authors]
def wizard_path(_list) = nil   # books has no wizard
```

### Shared-component change (the "no wizard" mechanism)
`app/components/admin/lists/show_component.html.erb:31` renders `link_to wizard_path_proc.call(list)`
unconditionally. Compute it into a local and guard:

```erb
<% wizard_link = domain_config[:wizard_path_proc].call(list) %>
<% if wizard_link.present? %>
  <%= link_to wizard_link, class: "btn btn-secondary" do %> … Launch Wizard … <% end %>
<% end %>
```

Behavior-neutral for music/games (real paths); books (nil) renders no button. This is the only touch to
shared list rendering.

### Routes / registry / views / nav
- Books admin namespace: `resources :lists` — **no** wizard/`items` nested routes (unlike games). List
  items ride the global shared `Admin::ListItemsController` (its `list.type.split("::")` auth already
  resolves `Books::List` → `"books"`).
- `DomainRouting::LISTS["Books::List"] = {domain: :books, listable_type: "Books::Book", item_label:
  "Book", path: ->(l) { admin_books_list_path(l) }, autocomplete_path: -> { search_admin_books_books_path }}`
  — powers the list show-page "add item" book typeahead.
- Views: one-line wrappers around the shared `Admin::Lists::*Component` (mirror `admin/games/lists/`).
- `DomainNav CONFIGS[:books][:items]` += `{label: "Lists", icon: :list, path: -> { admin_books_lists_path }}`.
- `Books::ListPolicy` already exists.

## Part 2 — Books Ranking Configurations

### Controller
`Admin::Books::RankingConfigurationsController < Admin::RankingConfigurationsController` +
`include Admin::DomainScopedAuth`, mirroring `Admin::Games::RankingConfigurationsController`:

```ruby
def policy_class = ::Books::RankingConfigurationPolicy
def domain_name  = "books"
def ranking_configuration_class = ::Books::RankingConfiguration
def ranking_configurations_path(**o) = admin_books_ranking_configurations_path(**o)
def ranking_configuration_path(rc, **o) = admin_books_ranking_configuration_path(rc, **o)
def new_ranking_configuration_path = new_admin_books_ranking_configuration_path
def edit_ranking_configuration_path(rc) = edit_admin_books_ranking_configuration_path(rc)
def execute_action_ranking_configuration_path(rc, **o) = execute_action_admin_books_ranking_configuration_path(rc, **o)
def index_action_ranking_configurations_path(**o) = index_action_admin_books_ranking_configurations_path(**o)
```

**No new views** — inherits the shared `app/views/admin/ranking_configurations/*`.

### Routes / registry / auth landmine / nav
- Books admin namespace:
  ```ruby
  resources :ranking_configurations do
    member { post :execute_action }
    collection { post :index_action }
  end
  ```
- `DomainRouting::RANKING_CONFIGURATIONS["Books::RankingConfiguration"][:path]` →
  `->(rc) { admin_books_ranking_configuration_path(rc) }` (currently `nil`).
- **Auth landmine (load-bearing):** the `path:` is what `Admin::DomainScopedAuth
  #domain_with_ranking_configuration_admin_for` keys on. Setting it makes books domain users resolve
  `:books` and gain access to the shared globally-routed `RankedLists` / `RankedItems` /
  `PenaltyApplications` controllers for books RCs. This **flips two existing denial tests** from redirect
  to success — update them, don't fight them:
  - `test/controllers/admin/ranked_lists_controller_test.rb:183` ("should deny access to a books ranking
    configuration for a user with only a books domain role" → now allowed; a books viewer may **read**).
  - the equivalent books-denial test in `penalty_applications_controller_test.rb`.
- `DomainNav CONFIGS[:books][:items]` += `{label: "Rankings", icon: :chart, path: -> { admin_books_ranking_configurations_path }}`.
- `Books::RankingConfigurationPolicy` already exists (gates create/update/destroy on `manage?`).
- "Refresh Rankings" / "Bulk Calculate Weights" run via the existing `ItemRankings::Books::Calculator`
  and `RankingConfiguration#calculator_service` — **no new code** — but Refresh's per-item date penalty
  is wrong until Part 3.

## Part 3 — Legacy date-penalty parity (the real "D8")

### What the legacy app does (`the-greatest-books/admin`)
The legacy books ranking has **no year-range / temporal-coverage penalty**. Its date penalty
(`app/lib/rankings/calculator.rb#calculate_score_penalty`) is a **per-book recency** penalty:

```
return max_pct/100.0  if list.yearly_award? || book.first_year_published.nil?
return nil            unless list.year_published && book.first_year_published
year_difference = list.year_published - book.first_year_published
  year_difference <= 0        → max_pct/100.0        # book newer than the list → full penalty
  year_difference > max_age   → nil                   # old enough → no penalty
  else                        → ((max_age - year_difference)/max_age) * max_pct / 100.0
```

bounded by the RC's `max_age_for_penalty` and `max_penalty_percentage`, toggled by
`apply_list_dates_penalty`.

### What the new app does (verified)
- The new `Rankings::WeightCalculatorV1#calculate_books_year_range` belongs to the per-list
  *temporal-coverage* penalty (`dynamic_type: :num_years_covered`). **None of the 4 books RCs apply it**
  (their dynamic penalties are voter-count/bias only), so it is **never called for books**. Dead code.
- The legacy recency penalty **is** ported — the shared `ItemRankings::Calculator#calculate_score_penalty`
  (`calculator.rb:90`) has the identical graduated formula, gated on `apply_list_dates_penalty?` +
  `max_list_dates_penalty_age` / `max_list_dates_penalty_percentage`.
- The **primary** books RC (#8 "May 2026") carries these, migrated from legacy:
  `apply_list_dates_penalty=true, max_list_dates_penalty_age=50, max_list_dates_penalty_percentage=80`.
  So the intent is clearly to run the legacy recency penalty. (Every domain's primary RC has the toggle on.)

### The bug
`calculator.rb:95` guards with `item.respond_to?(:release_year) && item.release_year.present?`.
`Music::Album`, `Games::Game`, and `Movies::Movie` all expose `release_year`; **`Books::Book` does not**
(it has `first_published_year`). So for **every book**, the penalty returns `nil` there — the primary
RC's date penalty is a silent no-op, and the new books rankings do not match the old site.

### The fix
1. **`Books::Book#release_year`** delegating to `first_published_year` (matches the generic item
   interface every other medium already satisfies; also fixes the known `MyListsController#csv_row` gap
   that calls `listable.release_year`).
2. Two legacy behaviors into the **shared** `ItemRankings::Calculator#calculate_score_penalty`
   (general rules — 6b-6):
   - `list.yearly_award?` → max penalty (`max_penalty_percentage / 100.0`). Live for books' 50 award
     lists; inert for music/games (0 award lists today).
   - `item.release_year` nil (when the RC applies the date penalty with age/pct set) → max penalty
     instead of the current skip. Re-ranks ~1% of music/games items (40 albums, 1,043 songs, 12 games)
     and 27% of books (33,948) — accepted correctness/parity change.
   **Order matters for parity:** legacy checks `yearly_award? || book-year-nil → max` *before* the
   `list.year_published` guard, so a yearly-award list with no `year_published` still max-penalizes. The
   new calc's `return nil unless list.year_published.present?` currently runs first — the two max-penalty
   checks must move ahead of it (and ahead of the `max_age`/`max_pct` presence guard, which they depend
   on), matching the legacy branch order: `yearly_award || nil-item-year → max`, then
   `nil list-year → none`, then `year_diff ≤ 0 → max`, `> max_age → none`, else graduated.
3. **Do not** touch `calculate_books_year_range` (moot for books).

## Testing

- **`admin/books/lists_controller_test.rb`** — index/CRUD/auth (books writer allowed, books viewer read,
  regular redirected); the show page renders with **no** Launch Wizard button.
- **`admin/books/ranking_configurations_controller_test.rb`** — index/CRUD/auth; `execute_action`
  (member) and `index_action` (collection) dispatch.
- **Registry units** — `LISTS["Books::List"]` resolves + `list_config` returns the books book typeahead;
  `RANKING_CONFIGURATIONS["Books::RankingConfiguration"][:path]` resolves.
- **Auth-landmine updates** — flip the two `ranked_lists` / `penalty_applications` books-denial tests to
  assert a books domain user is now **allowed** to read.
- **`Admin::Lists::ShowComponent`** — wizard button rendered for a games/music list, **not** for a books
  list (nil `wizard_path`).
- **`Books::Book#release_year`** — returns `first_published_year`.
- **`ItemRankings::Calculator#calculate_score_penalty`** (legacy parity, exercised via books): book with a
  year → graduated; `year_difference ≤ 0` → max; `> max_age` → none; **nil year → max**; **yearly-award
  list → max**. Add a regression asserting the two edge cases hold for a music item too (shared behavior).
- **Playwright** — `books/admin/lists.spec.ts` (index + show + add a book item via the live typeahead) and
  `books/admin/ranking_configurations.spec.ts` (index + create).

## Landmines

- **`Books::Book` lacks `release_year`** — the whole reason the legacy penalty silently no-ops; the
  shared calc's `respond_to?(:release_year)` guard hides it. Verify with a test that a book's penalty is
  non-nil once `release_year` exists.
- **RC `path:` gates auth** — adding it flips the `ranked_lists`/`penalty_applications` books-denial tests
  red by design; update them (they assert *read* access now).
- **`series`-style helper naming does not apply** — `lists`/`ranking_configurations` are regular plurals.
- **`raise_on_missing_callback_actions` is on** — grow `before_action only: […]` per action as usual.
- **Ship the DomainNav "Lists" + "Rankings" items with their routes** (every prior increment that forgot
  the nav item shipped a dead sidebar).
- **The nil-year / yearly-award edge cases are shared-calculator changes** — they touch music/games/movies
  rankings, not just books; the tests must pin the intended cross-domain behavior.

## Follow-ups (tracked, not in 6b)
- **Shared-mutation write-gating PR** — gate `ranked_lists` / `penalty_applications` / `list_items` /
  `list_penalties` mutations on domain write across all domains (the 6a `require_domain_write!` pattern),
  closing the pre-existing viewer-write gap 6b newly exposes for books.
- Inc 7 — full books admin Playwright suite mirroring games' nine specs.
