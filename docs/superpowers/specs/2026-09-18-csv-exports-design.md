# CSV exports — design

Date: 2026-09-18
Status: approved for planning

## 1. What this is

A "Download CSV" button on every rankings page (books, music albums, music songs, games),
on every saved-search page, and on every user list page. It exports **what the viewer is
looking at** — filters included — as a UTF-8 CSV with a BOM.

Access follows the legacy books site: sign-in required; a non-member gets the first 500
rows; a member gets everything. User lists are the exception — they keep today's uncapped
download for anyone who can see the list.

The full, unfiltered ranking for a member is served from a **pre-built file** regenerated
by the events that change it. Everything else is generated **on demand** and never stored.

Out of scope: the creator rankings (books authors, music artists — a different page shape),
scheduled/emailed exports, formats other than CSV, an export history per user.

## 2. Why the legacy design failed, and what replaces it

The legacy books site (`../the-greatest-books/admin`) had a `CsvExport` row keyed by
`(name, url_path, book_limit)` with a 24-hour `REFRESH_AFTER`, refreshed by a job that the
download itself enqueued, and the resulting file was additionally cached by nginx. Three
things went wrong, each fixed by a specific decision below:

| Legacy failure | Cause | Decision here |
|---|---|---|
| Files served up to a day (or more) behind the site | TTL-based refresh; nginx cache on top | No TTL anywhere. Pre-built files regenerate on the event that changes ranks (D4) and nightly for metadata (D5); nothing else can hold a CSV (D3). |
| The ~20,000-row member export timed out and errored | Generated inline in the request | The unfiltered member export is never generated inline (D2). On-demand exports batch and use SQL aggregation (§10). |
| The first download after expiry paid for regeneration | Refresh triggered by the download | Regeneration is triggered by the ranking calculation and the nightly job; a download only enqueues when there is no file at all. |

## 3. Measurements that shaped this (dev DB, MacBook Air, 2026-09-18)

| Export | Rows | Time | Size |
|---|---|---|---|
| Books primary, authors only | 21,392 | 2.0 s | 1.2 MB |
| Books primary, authors + countries + categories + language, preloads | 21,392 | 9.95 s | 4.8 MB |
| First 500 rows, preloads | 500 | 0.02 s | — |
| Music albums / songs / games primaries | 3,905 / 5,084 / 1,484 | small | — |
| Saved searches | ≤ 10,000 (OpenSearch `max_result_window`) | not measured | — |
| Largest user list | 24,521 items | already exported on demand today | — |

The 500-row export is free. The full books export is the only one whose cost matters, and
it is dominated by the many-to-many text columns.

## 4. Decisions

- **D1 — Export what is on screen.** Category, country, year and collection filters apply to
  the export. This rules out pre-building filtered files; filtered exports are on demand.
- **D2 — The unfiltered member export is a pre-built file.** One `CsvExport` row per
  `RankingConfiguration` with an ActiveStorage file on R2. A member download of an unfiltered
  ranking serves that file and never generates 20k rows in a request.
- **D3 — CSV never comes from a cached action.** The `index` actions are edge-cached for
  6 hours with the session cookie stripped; a `format.csv` there would let Cloudflare cache one
  viewer's file for everyone. Every export is its own action with `prevent_caching` and
  `require_signed_in!`.
- **D4 — Regenerate after every successful ranking calculation.** Both
  `CalculateRankingsJob` and `RankingConfigurations::RefreshJob` enqueue a regenerate on
  success. Ranks in the file are never behind the site by more than the job's run time.
- **D5 — Regenerate global configurations nightly.** Title fixes, author merges, category and
  country edits change the file's contents without touching `ranked_items`, and there is no
  cheap, honest way to detect that drift at download time (an author merge does not bump the
  book's `updated_at`; a `max(updated_at)` scan is a TTL in disguise). A nightly job caps that
  drift at 24 hours for the four exportable global configurations at under a minute of
  `low`-queue time. User-owned configurations regenerate on their own refresh only.
- **D6 — Files are proxied through Rails, never linked.** The R2 bucket is `public: true`, so
  a blob URL is a permanent unauthenticated link to the paid artifact. `rails_blob_path` is
  also out: its signed ids do not expire.
- **D7 — The membership gate is a cap, not a redirect.** `MembershipGate::FEATURES` gains
  `csv_export_full`, but `require_membership!` is not used: non-members get a file, just a
  shorter one.
- **D8 — The callout is a modal on the page, driven by the existing client-side state
  pattern.** Rankings pages cannot render per-viewer HTML, so the "top 500 — become a
  member" explanation is a static `<dialog>` opened by a Stimulus controller after checking
  the `tg_uid` cookie and `/membership_state`. The modal explains; the server enforces.
- **D9 — Not polymorphic.** Only ranking configurations get a stored file. If a saved search or
  list ever needs one, adding `exportable_type` is a small migration; carrying it now is a
  column nobody reads.
- **D10 — All ranking domains now, one shared core.** Books, music albums, music songs and
  games each get a row builder and a button; the model, services, jobs, concern, component
  and controller are shared.

## 5. Access rules

| Viewer is looking at | Member | Signed-in non-member | Anonymous |
|---|---|---|---|
| Unfiltered ranking (any configuration the viewer may see) | pre-built file, full | on demand, top 500 | sign-in modal |
| Filtered ranking | on demand, full | on demand, top 500 | sign-in modal |
| Saved search | on demand, up to 10,000 (OpenSearch window) | on demand, top 500 | sign-in modal |
| User list | on demand, full — unchanged | unchanged | unchanged (public lists download today) |

"Unfiltered" means no category, country, year, or collection filter. A user-owned
configuration at `/rc/:id` passes through `gate_ranking_configuration!` exactly as its page
does: shared or owner, else 404.

## 6. Data model

`bin/rails g model CsvExport` — one row per configuration:

| Column | Type | Meaning |
|---|---|---|
| `ranking_configuration_id` | bigint, FK, **unique index** | `RankingConfiguration has_one :csv_export, dependent: :destroy` |
| `status` | integer, `enum :status, {pending: 0, generating: 1, ready: 2, failed: 3}` | |
| `requested_at` | datetime | when the current claim was taken |
| `generated_at` | datetime | last successful generation; feeds the filename |
| `row_count` | integer | rows in the current file |
| `byte_size` | integer | bytes in the current file |
| `error_message` | text | last failure; cleared on success |
| `has_one_attached :file` | | the CSV on R2 (Disk in test). Re-attaching replaces the blob; ActiveStorage purges the old one through Sidekiq (already the ActiveJob adapter). |

`GENERATION_STALE_AFTER = 15.minutes`: a `generating` row older than that is treated as
abandoned (worker killed before its rescue) and may be re-claimed — the same idea as
`RankingConfiguration::REFRESH_STALE_AFTER`.

`claimable?` is `!generating? || requested_at.nil? || requested_at < GENERATION_STALE_AFTER.ago`
(a claim always stamps the timestamp, so a missing one means the row was never properly
claimed), and `CsvExport.claimable` is the same predicate as a scope, kept beside it so the SQL
the claim issues cannot drift from it. `downloadable?` is `file.attached?` regardless of
`status`: `Generate` attaches only on success, so an attached file is always a good file, and a
member keeps downloading the last good one while a regeneration runs or after one fails. There
is no uniqueness validation — it would turn a race on a configuration's first row into
`RecordInvalid`, which `find_or_create_by!` does not rescue; the unique index is the invariant.

## 7. Code layout

```
app/lib/csv_exports/
  registry.rb              # exportable configuration types -> row builder + filename slug
  writer.rb                # BOM + header + rows -> IO; shared by every path
  ranked_items.rb          # relation + row builder + limit -> CSV (pre-built and on demand)
  saved_search.rb          # pages Books::SavedSearchQuery up to the cap / 10,000
  user_list.rb             # today's MyListsController CSV code, moved verbatim
  limits.rb                # limit_for(user): nil for members, 500 otherwise
  books/ranked_book_row.rb
  music/ranked_album_row.rb
  music/ranked_song_row.rb
  games/ranked_game_row.rb
app/lib/services/csv_exports/
  request_generate.rb      # find_or_create + atomic claim + enqueue; Result
  generate.rb              # build file, attach, stamp; Result
app/sidekiq/csv_exports/
  generate_job.rb          # queue low, retry: false
  refresh_global_job.rb    # nightly fan-out
app/models/csv_export.rb
app/controllers/concerns/csv_exportable.rb
app/components/csv_exports/download_button_component.rb (+ .html.erb)
app/javascript/controllers/csv_export_controller.js
```

`CsvExports::Registry` mirrors `RankingConfigurations::Registry`: one `Entry` per exportable
configuration class (`Books::RankingConfiguration`, `Music::Albums::RankingConfiguration`,
`Music::Songs::RankingConfiguration`, `Games::RankingConfiguration`) carrying the row builder
class, the unfiltered relation builder (`->(config) { … }`), and a filename slug. Authors and
artists configurations are absent, which is what makes them a no-op everywhere below.

Each row builder declares `HEADERS`, `preloads` (the `includes` hash for one batch), and
`row(ranked_item)`.

## 8. Services, jobs, triggers

**`Services::CsvExports::RequestGenerate.call(ranking_configuration:)`**
1. Return `success?: false, data: {reason: :not_exportable}, errors: [<message>]` if the registry
   has no entry for the configuration's type (the symbol travels in `data[:reason]`, the human
   message in `errors`, as in `Services::RankingConfigurations::RequestRefresh`).
2. `CsvExport.find_or_create_by!(ranking_configuration:)` — Rails falls through to
   `create_or_find_by!` on a miss, which absorbs two callers racing past the find.
3. One atomic claim through the `claimable` scope: `UPDATE csv_exports SET status = generating,
   requested_at = now() WHERE id = ? AND (status <> generating OR requested_at IS NULL OR
   requested_at < now() - 15 min)`. Zero rows updated → `success?: false, data: {reason:
   :already_generating}`.
4. `CsvExports::GenerateJob.perform_async(csv_export.id)`. If the enqueue raises (Redis
   unreachable), release the claim into `failed` with the message and return failure, so the
   next trigger can retry instead of waiting out the 15 minutes. The release is scoped to the
   claim this call holds (`status = generating AND requested_at = <the stamp it wrote>`), so a
   stale reclaim by another caller in the meantime is never clobbered.

**`Services::CsvExports::Generate.call(csv_export:)`**
1. Resolve the registry entry; build the unfiltered relation for the configuration.
2. Stream it through `CsvExports::RankedItems` with `limit: nil` into a `Tempfile`.
3. `ActiveStorage::Blob.create_and_upload!(io:, filename:, content_type: "text/csv")` **first**,
   then one `update!(file: blob, status: ready, generated_at, row_count, byte_size, error_message:
   nil)`. Upload-then-attach, not `attach(io:)`: on a persisted record `attach` swaps the
   attachment rows before uploading (the upload runs in `after_commit`), so a storage failure
   would leave the row pointing at a blob that was never written.
4. On any exception: `status: failed, error_message: e.message.truncate(500)` (scoped to the
   claim this run holds), return a failure Result; the job re-raises so it lands in the Sidekiq
   log. The previously attached file is untouched — a download during a failed regeneration
   still serves the last good file.

**`CsvExports::GenerateJob`** — `sidekiq_options queue: :low, retry: false`. The row carries the
outcome; a silent Sidekiq retry would run while the row says `failed`, the same reasoning as
`RankingConfigurations::RefreshJob`. Returns quietly if the row was deleted while queued.

**`CsvExports::RefreshGlobalJob`** — in `config/schedule.yml` at `30 4 * * *` (after author
rankings at 04:00). For each `RankingConfiguration.global.active` whose type has a registry
entry, calls `RequestGenerate`. User-owned and archived configurations are skipped.

**Triggers**

| Event | Action |
|---|---|
| `CalculateRankingsJob` success | `RequestGenerate` for that configuration (any type; non-exportable types return `:not_exportable`) |
| `RankingConfigurations::RefreshJob` success | same |
| Nightly cron | `RefreshGlobalJob` |
| Member downloads an unfiltered ranking with no `ready` file | `RequestGenerate`, then the "being prepared" response (§9) |
| Admin "Regenerate" button | `RequestGenerate` |
| Admin bulk/sync `calculate_rankings` outside a job, rake tasks | not hooked; the nightly job backstops |

**Admin.** `admin/ranking_configurations/show` gains a "CSV export" block: status,
generated at, rows, size, error, and a Regenerate button (POST to a new admin route that calls
`RequestGenerate`).

## 9. Endpoints

All under the domain's existing host constraint; `.csv` is the only format.

| Route | Controller action | Filter params (query string) |
|---|---|---|
| `GET (/rc/:ranking_configuration_id)/export.csv` on books | `Books::RankedItemsController#export` | `category_id`, `country_id`, `year_start`, `year_end`, `collection` |
| `GET (/rc/:ranking_configuration_id)/albums/export.csv` on music | `Music::Albums::RankedItemsController#export` | `year`, `year_mode` |
| `GET (/rc/:ranking_configuration_id)/songs/export.csv` on music | `Music::Songs::RankedItemsController#export` | `year`, `year_mode` |
| `GET (/rc/:ranking_configuration_id)/video-games/export.csv` on games | `Games::RankedItemsController#export` | `year`, `year_mode` |
| `GET /searches/:id/export.csv` | `SavedSearchesController#export` | none (the search's criteria) |
| `GET /my/lists/:id.csv` | `MyListsController#show` — unchanged | `sort` |

Filters arrive as query params rather than re-mirroring the page's path grammar. Each
`export` action parses them with the same code its `index` uses (`Books::FilterParams`,
`parse_year_filter`), so the relation is identical by construction. The music and games
export routes are declared **before** their `albums/:year` / `songs/:year` /
`video-games/:year` siblings so `export.csv` can never be captured as a year. `?collection=` is
deliberately rejected on the books `index` to prevent soft-duplicate URLs; on an uncached,
`nofollow`, sign-in-only endpoint that concern does not apply, and `export` resolves it
through `Collections::Registry.find(:books, slug)` (404 on unknown).

**`CsvExportable` concern** — included by every controller with an export action:

- `before_action :prevent_caching, :require_signed_in!, only: [:export]`
- `rate_limit to: 20, within: 1.hour, by: -> { current_user.id }, only: [:export]` on
  `Rails.application.config.x.rate_limit_store`
- `send_csv(io_or_string, filename:)` — `Content-Type: text/csv; charset=utf-8`,
  `Content-Disposition: attachment`, `X-Robots-Tag: noindex`
- `serve_prebuilt_or_prepare(ranking_configuration)` — for the member + unfiltered case:
  - `ranking_configuration.csv_export` exists and `downloadable?` (a file is attached, whatever
    the latest attempt's `status`) →
    `send_csv(csv_export.file.download, filename: "<slug>-<generated_at date>.csv")`
  - otherwise → `RequestGenerate.call(ranking_configuration:)` (which creates the row if
    needed), then render `csv_exports/preparing` (HTML, status 202, `no-store`, with an HTTP
    `Refresh: 15` header — the header form of a meta refresh, which every browser honours) —
    "Your export is being prepared." Not a flash: the cached rankings page skips the session, so
    a flash set here would never render there. The view renders in the controller's own domain
    layout.
- `export_limit` — `CsvExports::Limits.limit_for(current_user)`

The books `export` action, as the reference:

```ruby
def export
  filters = Books::FilterParams.call(params)
  collection = params[:collection].present? && (Collections::Registry.find(:books, params[:collection]) || raise(ActiveRecord::RecordNotFound))
  unfiltered = filters.categories.empty? && filters.countries.empty? && filters.year_start.blank? && filters.year_end.blank? && collection.nil?

  if unfiltered && current_user.member?
    serve_prebuilt_or_prepare(@ranking_configuration)
  else
    relation = Books::RankedBooksQuery.call(ranking_configuration: @ranking_configuration, categories: filters.categories, countries: filters.countries, year_start: filters.year_start, year_end: filters.year_end, collection: collection)
    send_csv CsvExports::RankedItems.call(relation:, row_class: CsvExports::Books::RankedBookRow, limit: export_limit), filename: export_filename
  end
end
```

`find_ranking_configuration` and `validate_ranking_configuration_type` already run for every
action on these controllers, so `/rc/` gating is inherited.

**Saved search export.** `SavedSearchesController#export` resolves the search with
`visible_to(current_user).find` (404, never 403), then `CsvExports::SavedSearch.call(search:,
limit:)` pages `Books::SavedSearchQuery.call(criteria:, owner: search.user, page:, per_page:
1000)` until the limit, an empty page, or `SavedSearchQuery.max_page(per_page: 1000)` (10),
whichever first. `hide_read` stays about the owner, as on the page.

**User lists.** `MyListsController#show`'s `format.csv` branch calls
`CsvExports::UserList.call(list:, items:)`. Output is byte-identical to today; the controller's
`build_csv`/`csv_headers`/`csv_row` helpers are deleted. The Download link is rendered by the
shared button component with `capped: false`, which emits a plain link — no Stimulus
controller, no modal — so an anonymous viewer of a public list downloads exactly as today.

`MembershipGate::FEATURES` gains
`csv_export_full: "Full CSV downloads (non-members get the top 500 rows)"`.

## 10. Generation and performance

One code path for both the pre-built file and on-demand exports:

```
relation.in_batches(of: 1000, order: :asc) -> batch.includes(row_class.preloads).order(:rank)
  -> row_class.row(ranked_item) -> CSV line -> IO (Tempfile pre-built, StringIO on demand)
```

Memory is flat at one batch regardless of total rows. The limit is applied to the relation
(`limit(500)`) before batching, so the non-member export runs one small query.

The many-to-many text columns (authors, countries, categories) are the 10-second cost in §3.
The plan's first task benchmarks a single `string_agg`-per-association subquery against the
preload version and keeps whichever is faster. Target: a 21k-row filtered member export in
under 3 s on the dev DB. If neither reaches it, the fallback is `ActionController::Live`
streaming so bytes flow immediately and no proxy sees a slow time-to-first-byte; the SQL version
is expected to make that unnecessary. Puma runs 5 threads; a few concurrent 3-second exports
are fine and the rate limit caps the blast radius.

## 11. The button and the modal

**`CsvExports::DownloadButtonComponent`** — rendered next to the filter bar on every rankings
page, beside the saved-search results header, and in place of the current Download link on
`/my/lists/:id`. Takes `export_path:`, `noun:` ("books", "albums", "songs", "games",
"results"), and `capped:` (false for user lists — a plain `<a>` with no controller and no
dialog). The component renders its own `<dialog>`, so it is rendered once per page.

```erb
<div data-controller="csv-export" data-csv-export-modal-value="csv_export_modal">
  <a href="<%= export_path %>" rel="nofollow" class="btn btn-sm btn-outline"
     data-action="csv-export#download" data-turbo="false">Download CSV</a>
</div>

<dialog id="csv_export_modal" class="modal">
  <div class="modal-box">
    <h3 class="text-lg font-bold">This download includes the top 500 <%= noun %></h3>
    <p class="py-4">Members can download the whole ranking and the full results of any filter or saved search.</p>
    <div class="modal-action">
      <a href="<%= export_path %>" class="btn btn-primary" data-turbo="false">Download top 500</a>
      <%= link_to "Become a member", membership_path, class: "btn btn-outline" %>
      <form method="dialog"><button class="btn btn-ghost">Cancel</button></form>
    </div>
  </div>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
```

Only v5 classes (`modal`, `modal-box`, `modal-action`, `modal-backdrop`, `btn-*`); the
existing `test/lint/daisyui_v4_classes_test.rb` guards it. The `<a href>` is real: with JS off or
failed, the link works and the server applies the correct cap. The modal explains; it never
enforces.

**`csv_export_controller.js`**, `download(event)`:

1. `event.preventDefault()`.
2. No `tg_uid` cookie → `document.getElementById("login_modal")?.showModal?.()` and return
   (the same check `user_list_widget_controller.js#open` uses; sign-in reloads the page).
3. `fetch("/membership_state", {headers: {Accept: "application/json"}, credentials: "same-origin"})`.
   `member: true` → `window.location = href`. Anything else, including a non-OK response or a
   thrown fetch → `showModal()` on the dialog. The fallback is safe in the direction that
   matters: a member who hits it sees one unnecessary modal, and "Download top 500" points at
   the same URL, so the server still gives them the full file.

## 12. Columns

| Source | Columns |
|---|---|
| Books ranking | Rank, Score, ID, Title, Authors, Year, Original language, Countries, Genres, Subjects, Locations, Page range, Word count, URL |
| Music albums ranking | Rank, Score, ID, Title, Artists, Year, Genres, URL |
| Music songs ranking | Rank, Score, ID, Title, Artists, Year, URL |
| Games ranking | Rank, Score, ID, Title, Year, Platforms, Companies, Genres, URL |
| Saved search | the books columns; Rank and Score from the search's ranking configuration, blank when unranked |
| User list | today's columns unchanged: Position, Title, Authors/Artists (where the listable has them), Year, Completed On (only when `completed_on_enabled?`) |

Multi-valued columns join with `", "`; genre/subject/location split on
`Category#category_type`, restricted to the domain's own category subclass and never a
soft-deleted category; the books Countries column leaves out the `unknown` placeholder country
exactly as the book page does (`Books::Country.filterable`); URL is the item's canonical public
page on its domain. Scores are
rounded to two decimals. Every file starts with a UTF-8 BOM. A ranking export contains only
ranked rows (`rank IS NOT NULL`) — the books page already excludes unranked items, and the
music and games pages list them last with no rank, which in a CSV is an empty Rank cell and
noise — so a music or games CSV can carry fewer rows than the page's total.

Filenames (`CsvExports::Registry.filename_for`): a global configuration's export is
`the-greatest-<slug>-rankings-<date>.csv` and a user-owned one is
`<configuration name parameterized>-<slug>-<date>.csv`, where `<date>` is `generated_at` for the
pre-built file and today for an on-demand one; saved search
`<search name parameterized>-<today>.csv`; user list unchanged.

## 13. Errors and security

- `Generate` failure → `failed` + message, last good file still served, job re-raises for the
  Sidekiq log, admin block shows it, and `failed` is claimable so the next trigger retries.
- Enqueue failure in `RequestGenerate` → claim released to `failed` immediately.
- On-demand generation raising (OpenSearch down for a saved search) → the normal 500 path;
  nothing is stored, so nothing is half-written.
- `blob.download` raising (R2 hiccup) → 500; the row is untouched.
- Every export response: `Cache-Control: no-store, private`, `X-Robots-Tag: noindex`; the
  button carries `rel="nofollow"`. No `robots.txt` change: the endpoint requires sign-in, so a
  crawler is redirected away before any CSV is built.
- Rate limit is per user, not per IP.
- No export action ever redirects to storage or emits a blob URL.
- Cell values are written as data, never escaped against spreadsheet formula evaluation: a
  handful of real titles begin with `+` or `-` ("---- You"), the values are admin-curated
  rather than user-supplied, and prefixing them would corrupt the value for every non-Excel
  consumer. A conscious decision, recorded so it is not mistaken for an oversight.

## 14. Testing

- **Model**: enum, `claimable?` across `pending`/`ready`/`failed`/fresh `generating`/stale
  `generating`, uniqueness on `ranking_configuration_id`, `dependent: :destroy`.
- **Services**: `RequestGenerate` — creates the row, claims, dedupes a second call, re-claims
  a stale claim, returns `:not_exportable` for an authors configuration, releases the claim
  when `perform_async` raises (Mocha). `Generate` — attaches a file whose bytes start with the
  BOM and the header line, stamps counts, clears `error_message`; on a raised exception sets
  `failed` and leaves the previous attachment in place.
- **Builders**: one test per row class pinning `HEADERS` and one row from fixtures; the
  `limit`; the saved-search pager stops at the cap, at an empty page, and at `max_page` (stub
  `BookAdvanced`); `CsvExports::UserList` output equals the current controller's output
  byte-for-byte (written **before** the controller is switched over).
- **Jobs**: `GenerateJob` calls `Generate` and is quiet on a deleted row; `RefreshGlobalJob`
  requests for exportable global active configurations and not for user-owned, archived, or
  authors/artists ones; `CalculateRankingsJob` and `RankingConfigurations::RefreshJob` request
  on success and not on failure.
- **Controllers** (behaviour only, per `docs/testing.md`): anonymous → redirect; non-member →
  200 with header + 500 lines; member unfiltered with a `ready` file → the file's bytes; member
  unfiltered without one → 202 and `RequestGenerate` called once; member filtered → on demand,
  uncapped, and the filter changes the rows; `/rc/` gating (private user-owned config → 404
  for a stranger); `no-store` on every export response; the rate limit trips on the 21st
  request; a `.csv` request to a cached `index` route never yields a CSV body (Rails' implicit
  `(.:format)` routes `/.csv` to `index`, which has no CSV template and answers 406), so no CSV
  can ever come from a cached action.
- **E2E** (`e2e/tests/books/rankings-csv-export.spec.ts` plus one each for music and games
  rankings, saved searches, and the existing my-lists spec updated): a signed-in non-member
  clicks Download, sees the modal (`getByRole("dialog")`), "Download top 500" yields a
  `.csv` download event; an anonymous click opens the login modal. The member path is
  controller-tested unless the E2E account is comped.
- `bin/rails test`, `bundle exec standardrb`, and the lint test must be green; no new warnings.

## 15. Rollout

1. Deploy. Run `CsvExports::RefreshGlobalJob.perform_async` once from a console to build the
   four global files; until then a member's first unfiltered download gets the "being prepared"
   page for a minute or two. Before that first run, confirm the R2 token has `DeleteObject`
   permission: this is the first place the app routinely *replaces* an attachment, so
   `ActiveStorage::PurgeJob` will delete the previous CSV on every regeneration — without the
   permission, old files accumulate silently.
2. `docs/features/csv-exports.md` is written as part of the work; the CSV section of
   `docs/features/user-lists.md` points at it.
3. No production data migration: `csv_exports` starts empty and fills itself.

## 16. Environment notes for the implementer

- `.ruby-version` is 4.0.6 and mise's global default is now 4.0.6 too (`mise use --global
  ruby@4.0.6`, 2026-09-18). A shell launched before that change still carries
  `ruby/3.4.2/bin` on `PATH`; `mise exec -- …` or a fresh session fixes it.
- `benchmark` is no longer a default gem in Ruby 4 — time things with
  `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.
- R2 credentials are present in `web-app/.env`, so pre-built generation works in development;
  tests use the Disk service at `tmp/storage`.
- The legacy site lives at `../the-greatest-books/admin` — read `app/services/csv_generator.rb`
  and `app/models/csv_export.rb` there for what not to repeat.
