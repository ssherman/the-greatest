# User-Owned Ranking Configurations

## Overview

Signed-in users create their own ranking configurations: name and describe
one, share it by link or keep it private, tune the six algorithm settings,
switch each catalogue penalty on or off with its own value, choose which lists
feed it, and view the result on the public `/rc/<id>` pages. Weights and
rankings are recalculated in the background on creation and on demand.

Books only for now. The core is domain-generic; see "Switching on a domain".

Design: `docs/superpowers/specs/2026-09-12-user-ranking-configurations-design.md`.

## Data model

Everything lives on `ranking_configurations` (STI, `Books::RankingConfiguration`):

| Column | Meaning |
|---|---|
| `global` / `user_id` | `global: false` + `user_id` = user-owned (pre-existing columns) |
| `user_shared` | the owner has shared it by link |
| `refresh_status` | enum `idle / queued / running / failed` (`refresh_*?` predicates) |
| `needs_refresh` | a setting, penalty or list changed since the last successful run |
| `refresh_requested_at` | set when a run is claimed; runs older than an hour are treated as abandoned |
| `last_refreshed_at`, `last_refresh_error` | shown on the manage page |
| `inherited_from_id` | the official configuration it was copied from (nil when started from scratch) |

Rules for user-owned rows only: `min_list_weight` 0..100, `description` ≤ 1000,
never `primary`, at most `RankingConfiguration::MAX_PER_USER` (5) per user per
type. Model-wide: `max_list_dates_penalty_age` ≤ 200.

A penalty is **on** when a `PenaltyApplication` row exists for it and **off**
when none does — the weight calculator already skips penalties without a row.

## Where the code is

- `app/lib/ranking_configurations/registry.rb` — one `Entry` per user-creatable
  configuration class: classes, penalty types, public path helpers.
- `app/lib/ranking_configurations/penalty_rows.rb`, `missing_lists_query.rb` —
  read-only helpers for the form and the lists page.
- `app/lib/services/ranking_configurations/{create,save,add_lists}.rb` — the
  transactional writes.
- `RankingConfiguration#request_refresh!` — one atomic `UPDATE … WHERE` that
  claims the lock and enqueues `RankingConfigurations::RefreshJob`.
- `app/sidekiq/ranking_configurations/refresh_job.rb` — weights then rankings,
  queue `low`, `retry: false`; the outcome lands on the row.
- `app/controllers/my/ranking_configurations_controller.rb` and
  `my/ranking_configurations/lists_controller.rb` — global `/my/rankings`
  routes, domain from `Current.domain`, owner-only, never cached.
- `app/policies/ranking_configuration_policy.rb` — ownership. Every
  `authorize` passes `policy_class:` explicitly because Pundit's default for a
  `Books::RankingConfiguration` is the admin policy.
- `app/controllers/concerns/ranking_configuration_gating.rb` — `/rc/:id`
  visibility: global → everyone; user-owned → shared or owner, else 404.
- `Cacheable#cache_for_*` — return `prevent_caching` for a user-owned
  configuration, so no page under `/rc/` for one is ever edge-cached.
- `app/views/shared/_custom_ranking_banner.html.erb` — rendered by the domain
  layout when the gating concern set `@custom_ranking_configuration`.

## Refresh throttling

- A refresh request during a run is rejected before the rate limit sees it.
- `rate_limit to: 5, within: 24.hours` keyed by `current_user.id` on the shared
  Redis store (`config/initializers/rate_limit_store.rb`).
- The automatic run on create never passes through the controller action, so
  it does not count.
- `low` is strict-priority behind `critical` and `default` (`config/sidekiq.yml`).
- Admin bypasses all of this: `Admin::RankingConfigurationsController`'s
  bulk actions run against every row of the type, user-owned included, when no
  ids are selected, and its per-row "Refresh Rankings" action calls
  `calculate_rankings_async` directly -- it does not go through
  `request_refresh!`, so it ignores the owner lock and never touches
  `refresh_status`/`needs_refresh`/`last_refresh_error`.

## Search indexing

Nothing indexes a user-owned configuration: `Books::Book#primary_ranked_item`
is scoped to `default_primary`, `Books::ReindexRankedFieldsJob` loads the
primary itself, and the refresh job enqueues no reindex. `CalculateRankingsJob`
only triggers author rankings and the reindex for the primary.

## Switching on a domain

Add the domain's entries to `RankingConfigurations::Registry::ENTRIES` (two for
music — albums and songs — which turns on the kind chooser on `new`), a "My
Rankings" nav link, the banner `render` line in that domain's layout, and an E2E
spec under `e2e/tests/<domain>/`. No controller, model, job or policy changes.

## Testing

- Model, registry, query, service, job and policy tests under `test/`.
- `test/controllers/my/**` covers CRUD, refresh, the cap, the state endpoint,
  lists, search, Turbo Stream replies, frame-trapped links, and an N+1 guard.
- `test/controllers/books/*` pins `/rc/` gating and cache headers for every
  books controller that resolves a configuration.
- `e2e/tests/books/account/ranking-configurations.spec.ts` — owner flow; uses
  one of the E2E account's five daily refreshes per run.
