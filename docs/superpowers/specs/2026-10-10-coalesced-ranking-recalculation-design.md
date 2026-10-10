# Coalesced ranking recalculation

**Date:** 2026-10-10
**Status:** implemented on branch worktree-coalesce-ranking-recalcs

## Problem

Merging books from the duplicate-candidates queue filled Sidekiq's `default` queue with
`CalculateRankingsJob`s. The legacy books app had the same problem, and these jobs are the
most expensive work the app does. A books primary run takes 5-10 minutes.

The cause is that every trigger enqueues its own run and nothing coalesces them:

- Each of the five list-based mergers (`Books::Book`, `Games::Game`, `Music::Album`,
  `Music::Song`, `Music::Artist`) runs `schedule_ranking_recalculation` after commit. For
  **every** configuration that ranks the source or target, it enqueues
  `BulkCalculateWeightsJob.perform_async` and `CalculateRankingsJob.perform_in(5.minutes)`.
- In dev, 19,209 ranked books sit in 3 configurations (the primary plus two members'
  rankings) and 2,181 sit in 2. So 500 merges queue about 1,500 ranking runs and 1,500 weight
  runs. Each primary run then queues `Books::CalculateAuthorRankingsJob`,
  `Books::ReindexRankedFieldsJob` and a CSV regeneration.
- `default` has 5 threads, so several full recalculations of the same configuration run at
  once, each in its own transaction over the same ~21k `ranked_items` rows.
- The weights job and the rankings job race. Nothing guarantees the weights finish inside the
  5-minute head start.
- `Books::Author::Merger` enqueues a full author-rankings run on every author merge.
- Members' rankings are recalculated through `CalculateRankingsJob`, which bypasses the
  `refresh_status` flow their manage page reads.

The `defer_rankings:` opt-out on the book and author mergers only helps the Goodreads replay.
Merges from the admin UI never use it.

## Goals

- A burst of changes to one configuration produces one recalculation, not one per change.
- Two recalculations of the same configuration never run at once.
- Weights always finish before rankings start.
- This holds for every domain and every trigger, not only book merges.
- Members' rankings stay correct after a merge without the member doing anything.

## Non-goals and accepted trade-offs

- **A change that lands while a run is in progress is not guaranteed its own run.** It waits
  for the next trigger. This is deliberate: triggers are frequent, and public pages are served
  from the Cloudflare cache anyway. Do not add rerun-if-changed-mid-run machinery.
- No new gem (no `sidekiq-unique-jobs`), no Redis lock, no cron sweep.
- No change to the year configurations. `Services::Lists::GenerateDynamicLists` already
  calculates them synchronously.
- No change to the music "Refresh artist ranking" / "Refresh all artists rankings" admin
  actions, `BulkCalculateWeightsJob`, or the admin "Bulk Calculate Weights" action.
- No new cascade. Album and song recalculations do not cascade into music artist rankings
  today, and this design does not add that.

## Prior art

- **Legacy app** (`RefreshBookRankingsJob.queue_job`): `SET NX EX 15.minutes` on a Redis key,
  then `perform_in(5.minutes)`, with the key deleted in `ensure`. It bounds the queue to one run.
  Its key can expire during a long run and let a duplicate in, and its state is invisible.
- **This repo:**
  - `Services::RankingConfigurations::RequestRefresh` claims the configuration row with one
    conditional UPDATE and takes over a stale row after `REFRESH_STALE_AFTER` (1 hour).
  - `RankingConfigurations::RefreshJob` runs weights, then rankings, then the CSV, and records
    its state in `refresh_status`.
  - Both currently serve only members' rankings. This design extends them to every
    configuration.

## Design

### 1. `RequestRefresh` becomes the only way to ask for a recalculation

`Services::RankingConfigurations::RequestRefresh.call(config:, delay: 0)`

- **Claim:** keep the current conditional UPDATE: `idle`/`failed` → `queued`, or a stale
  in-progress row (`refresh_requested_at` older than `REFRESH_STALE_AFTER`) → `queued`.
- **Refused claim (already `queued` or `running`):** return the existing `:already_running`
  failure. This refusal is the coalescing: every trigger after the first in a burst lands here
  and does nothing.
- **Enqueue:** `RefreshJob.set(queue: queue_for(config)).perform_in(delay, config.id)`.
  - Global configurations (`user_id` nil): `default`.
  - User-owned configurations: `low`. That is `RefreshJob`'s current queue, and strict queue
    priority keeps these behind `critical` and `default`.
- **Enqueue failure:** unchanged. The claim is released into `failed` with the reason.
- **`RequestRefresh.call_for_ids(ids, delay: 0)`:** loads the configurations by id (nil, empty
  and duplicate ids are fine; missing ids are skipped) and calls `call` for each. The mergers,
  verdicts and the repair-verdicts controller hold ids, not records.
- `RankingConfiguration#calculate_rankings_async` is deleted. Its one caller, the admin
  "Refresh Rankings" action, calls `RequestRefresh` directly. Business logic stays in the
  service, not on the model.

**Delays:**

| Trigger | Delay | Why |
|---|---|---|
| Mergers, verdict application, provisional revert | `5.minutes` | Lets a burst collect before the run starts |
| Admin "Refresh Rankings", member "Refresh", dynamic lists, author cron, primary → authors follow-up | `0` | One deliberate request; nothing to wait for |

### 2. `RefreshJob` runs every configuration

`RankingConfigurations::RefreshJob#perform(ranking_configuration_id)` keeps its current shape:

1. Return if the configuration was deleted while queued.
2. **Start only from `queued`:** one conditional UPDATE, `queued` → `running` with
   `needs_refresh: false`, and the same UPDATE stamps `refresh_requested_at` to the start time, so
   the stale window measures the run rather than the wait. If no row changes, return without calculating. This keeps two runs of
   the same configuration from overlapping even when a stale claim let a second job into the
   queue. That can happen if the queue is so backed up that a job waits longer than
   `REFRESH_STALE_AFTER` to start.
3. `Rankings::BulkWeightCalculator.new(config).call`; raise on errors. A list-less
   configuration (books authors, music artists) has no `ranked_lists`, so this is a no-op for
   it.
4. `config.calculate_rankings`; raise on failure.
5. `refresh_status: idle`, `last_refreshed_at`, `last_refresh_error: nil`.
6. **New:** if the configuration is a `Books::RankingConfiguration` and
   `default_primary?`, then:
   - request a refresh of `Books::Authors::RankingConfiguration.default_primary` with `delay: 0`
     (skipped if there is none)
   - enqueue `Books::ReindexRankedFieldsJob`

   This is the same gate `CalculateRankingsJob` uses today, so members' rankings and year
   rollups still never trigger site-wide side effects. Both calls must not turn the finished run
   into `failed`: log and continue, as the CSV request already does.
7. CSV regeneration request, unchanged.

The rescue (`failed`, `needs_refresh: true`, `last_refresh_error`) and `retry: false` are
unchanged. The next trigger acts as the retry.

The class comment that says it "calls the calculators directly rather than
CalculateRankingsJob so none of the primary-only side effects can follow" is rewritten. The
gate in step 6 is now what keeps them out.

### 3. Call sites

| Call site | Today | After |
|---|---|---|
| `Books::Book::Merger`, `Games::Game::Merger`, `Music::Album::Merger`, `Music::Song::Merger`, `Music::Artist::Merger` `#schedule_ranking_recalculation` | weights job + `CalculateRankingsJob.perform_in(5.min)` per configuration | `RequestRefresh(delay: 5.minutes)` per configuration |
| `Books::Author::Merger#schedule_ranking_recalculation` | `Books::CalculateAuthorRankingsJob.perform_async` | `RequestRefresh(delay: 5.minutes)` on `Books::Authors::RankingConfiguration.default_primary` (skip if nil) |
| `Services::Books::GoodreadsReplay::ApplyVerdicts#queue_follow_ups` | `@reweigh` gets weights + delayed run; `@rankings - @reweigh` gets an immediate run; `:author_rankings` follow-up enqueues the author job | `RequestRefresh(delay: 5.minutes)` for each id in `@rankings \| @reweigh`; the `:author_rankings` follow-up requests the authors primary. The reweigh/recalculate split goes away because every run reweighs |
| `Admin::Books::RepairVerdictsController#revert_provisional` | `CalculateRankingsJob.perform_async` per id | `RequestRefresh(delay: 5.minutes)` per id |
| `Services::Lists::GenerateDynamicLists#recalculate_primary` | `CalculateRankingsJob.perform_async(main.id)` | `RequestRefresh(delay: 0)` |
| `lib/tasks/dynamic_lists.rake` | `CalculateRankingsJob.perform_async(main.id)` | `RequestRefresh(delay: 0)` |
| `Actions::Admin::RefreshRankings` | `config.calculate_rankings_async`; always "queued" | `RequestRefresh.call(config:)`; on `:already_running`, report that a run is already queued or running instead of claiming success |
| `Books::CalculateAuthorRankingsJob` (04:00 cron) | runs `calculate_rankings` inline | `perform` becomes a `RequestRefresh(delay: 0)` on the authors primary, so it cannot overlap a run already scheduled |

`GenerateDynamicLists#recalculate_primary` still runs `call_for_ids` on the two generated
lists synchronously. That is now redundant with the job's full weights pass, but it is cheap and
removing it is out of scope.

Every caller runs after its transaction commits, as the mergers already do. A failed
`RequestRefresh` Result there is logged and ignored. A merge that committed must not raise
because its follow-up could not be queued.

`defer_rankings:` stays on the book and author mergers. The replay still collects affected
configurations and requests each once at the end. With coalescing that is an optimisation, not
a correctness requirement.

### 4. Retiring `CalculateRankingsJob`

Jobs already sitting in Redis at deploy time (scheduled, enqueued, retrying) name
`CalculateRankingsJob`. If the class is deleted outright, each of those jobs raises `NameError`
and ends up a dead job.

- **This release:** `CalculateRankingsJob#perform(id)` becomes a shim. It looks up the
  configuration, returns if it is missing, and calls `RequestRefresh.call(config:)`. The thousands
  of queued copies collapse into one run per configuration. The class comment says it is
  transitional and names the follow-up.
- **Follow-up release:** delete the shim and its test. Add this as a line to the plan's
  final task, not as a separate spec.

## Failure modes

| Failure | Result |
|---|---|
| Calculation raises | Row `failed` + `last_refresh_error`; the next trigger claims it |
| Redis unreachable at enqueue | Claim released into `failed`; the caller logs and continues |
| Worker killed mid-run (OOM, hard kill) | Row stays `running` for up to `REFRESH_STALE_AFTER` (1 h), then the next trigger takes it over. Runs take 5-10 minutes, so 1 hour is well clear |
| Graceful Sidekiq restart mid-run | Sidekiq pushes the job back and raises `Sidekiq::Shutdown` in the running one; the job hands the row back to `queued` (only if still `running`) and re-raises, so the pushed-back job reruns |
| Configuration deleted while queued | Job returns early |
| Change lands during a run | Waits for the next trigger (accepted) |

## Testing

Minitest. External calls stubbed with Mocha.

- **`RequestRefresh`:**
  - one job on the first call; none on a second call while `queued` or `running`
  - `delay` reaches `perform_in`
  - queue is `default` for a global configuration and `low` for a user-owned one
  - a stale row can be taken over
  - an enqueue failure releases the claim into `failed`
- **`RefreshJob`:**
  - weights run before rankings
  - a list-less configuration completes
  - the authors refresh request and the reindex follow only for the books default primary,
    not for a member's ranking or a non-primary global one
  - a failing follow-up does not turn a finished run into `failed`
  - the row ends `idle` on success and `failed` on error
- **Mergers:** each merger's ranking test asserts `RequestRefresh` with `delay: 5.minutes` per
  affected configuration in place of the two jobs.
- **Coalescing:** a behaviour test under `Sidekiq::Testing.fake!` runs three book merges that
  share configurations and asserts exactly one `RefreshJob` per configuration. This is the bug
  being fixed.
- **Call sites:** `ApplyVerdicts`, `RepairVerdictsController#revert_provisional`,
  `GenerateDynamicLists`, the `dynamic_lists` rake task, `Actions::Admin::RefreshRankings`
  (including the refused-claim message), `Books::CalculateAuthorRankingsJob`.
- **Shim:** `CalculateRankingsJob` requests a refresh and tolerates a missing configuration.
- No Playwright test. No user-facing page or flow is new; the only visible change is the admin
  flash text.

## Documentation

- `docs/features/rankings.md`: a short "Recalculation is coalesced" section covering the
  single entry point, the claim, the delays, and the accepted mid-run trade-off.
- Update references in `docs/features/record-merge.md`,
  `docs/features/user-ranking-configurations.md`, `docs/features/csv-exports.md`,
  `docs/features/books-provisional-records.md`, and `docs/launch-todo.md` §1 step 2.
