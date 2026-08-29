# Public list submission — design

Visitors, signed in or anonymous, submit a list ("Rolling Stone's 500 Greatest Albums") for review.
One shared submission path serves four list types across three domains. The legacy books site had
this feature and it worked; music has a partial version already. This unifies both, hardens the
anonymous write path, and closes a live content leak the feature would otherwise amplify.

## What exists today

### The schema is already built for this

`lists` already carries `submitted_by_id` (FK `users`, nullable) and
`status` `{unapproved: 0, approved: 1, rejected: 2, active: 3}`. The books data migration carries
`lists.submitted_by_id` across from legacy. No new table is needed.

### Music already has a submission form

`Music::ListsController#new/#create` (routed `resources :lists, only: [:index, :new, :create]`)
accepts an anonymous submission, forces `status: :unapproved`, sets `submitted_by` when signed in,
and renders a 291-line form in `app/views/music/lists/_form.html.erb`. Books and games have nothing.

Measured against `CorrectionsController`, which solved this exact problem shape, it is missing:

- any rate limit — anonymous unbounded writes
- a honeypot
- `prevent_caching` on `create`
- length caps on `name`, `description`, `raw_content`
- an admin notification email
- **a thank-you the submitter can actually see.** It redirects with `notice:` to
  `music_lists_path`, which is `cache_for_index_page`'d. Public layouts render no flash, so that
  message has never been shown to anyone. Its controller test asserts on `flash[:notice]` and
  passes.

### The downstream already exists

The admin list wizard (source → parse → enrich → validate → review → import → complete, persisted in
`lists.wizard_state`) turns `raw_content` into resolved `list_items` via per-domain AI parsers.
Music albums, music songs and games have wizard controllers. Books has the parser
(`Services::Ai::Tasks::Lists::Books::RawParserTask`) but no wizard —
`Admin::Books::ListsController#wizard_path` returns `nil`.

## What legacy does

`the-greatest-books/admin`:

- No `SubmittedList` model. The public `create`s a row in the same `lists` table, distinguished only
  by `status` and a nullable `submitted_by_id`.
- `ListsController#new/#create` — no authentication, no authorization, five fields
  (`name`, `source`, `url`, `description`, `formatted_text`).
- `GET /lists/pending_lists` — a **public** table of every non-active list, including rejected ones,
  with submitter-supplied URLs rendered as links.
- `GET /lists/help` — predates the form and still tells users to email instead.
- On create, a plaintext SendGrid email to `contact@thegreatestbooks.org`, built and sent
  **synchronously in the request**, with no retry.
- Promotion to live is manual: an admin sets `status` to `active` and a `RankedList` must exist.
  There is no "approve" action anywhere.

### What is wrong with it

1. **Zero anti-spam.** No captcha, honeypot, rate limit, or `Rack::Attack`. The Gemfile has no
   anti-spam gem at all.
2. **Strong params are wider than the form** — `list_params` permits `number_of_voters`,
   `location_specific`, `category_specific`, `voter_count_unknown`, `voter_names_unknown`,
   `year_published`, `yearly_award`, all ranking-weight inputs, while the form exposes none of them.
3. **The moderation queue is public**, rejected rows included, with submitter URLs linked.
4. `ListPolicy#edit?` calls `user.admin?` on a nil user, so `GET /lists/:id/edit` raises
   `NoMethodError` for a logged-out visitor rather than redirecting.
5. `url` has no validation and no uniqueness, so duplicate submissions are accepted silently.
6. **Essentially no tests** — `new`, `create`, `pending_lists`, `edit` and `update` are all
   untested; `test/models/list_test.rb` is a single presence matcher.

### The legacy data — this feature earns its keep

209 lists submitted by **11 distinct people**, of which **152 are live on the site today** — a 73%
acceptance rate, achieved with no spam protection whatsoever.

| Submitter | Submitted | Now active |
|---|---|---|
| scruton152@ | 70 | 61 |
| mmilam8405@ | 69 | 30 |
| shane.sherman@ | 44 | 40 |
| nathanielstoll+tgb@ | 11 | 10 |
| 7 others | 15 | 11 |

Submission volume is bursty: **25 in a single day** by one person, and 8 separate days exceeded 5.
That directly sizes the rate limit — a flat 5/hour would have rejected the most valuable
contributors, the trap corrections hit and documented.

The 1,304 unapproved music lists are **not** submissions: all created in 2026, none with a
submitter, and only 1 of 1,304 has a URL or pasted content. That is import backlog. The public music
form has received roughly one real submission ever.

## Scope

In scope: the shared submission machinery; books, games, music albums and music songs wired to it;
the public form and thanks page; the admin filter; the owner email; and closing the music list-show
leak.

Out of scope: the books admin list wizard (books submissions land in the queue with their pasted text
intact and are processed as they are today); a public pending-lists page; a one-click approve action;
any change to how a list goes live.

## Prerequisite: close the music list-show leak

`Music::Albums::ListsController#show` and `Music::Songs::ListsController#show` do
`List.find(params[:id])` with **no status filter**, unlike `Books::ListsController#show`, which does
`Books::List.where(status: :active).find_by!(id:)`. Their `index` actions likewise join
`ranked_lists` with no status filter, where books goes through `ListsQuery`, which filters
`status: active`.

So a list submitted through the music form is immediately live at `/albums/lists/:id`, edge-cached
24h, indexable (music's robots helper renders `index, follow` unless `@indexable` is explicitly
false), with the submitter's URL rendered as an outbound link carrying `noopener noreferrer` but
**not `nofollow`**.

Today that is unexploited only because nobody uses the form. Advertising submission on three domains
turns it into an SEO-spam vector on live sites. This ships first, on its own.

- Scope both `show` actions to `status: :active`, matching books.
- Apply the same filter to both `index` actions.
- Add `rel="nofollow"` to the source-URL link on list show pages across all domains.

**Deploy step:** exactly one live page changes behaviour. `Music::Albums::List #10093`
("500 CDs You Must Own Before You Die") is `approved`, not `active`, and has a weighted `RankedList`,
so it is plainly meant to be live — set it to `active`. The only other two `RankedList` rows on
non-active lists are `Books::List` #789 and #886, which already 404 today.

**Verified against the test suite.** The `music_songs_list` fixture is `status: 1` (`approved`) while
`music_albums_list` is already `status: 3` (`active`) — an asymmetry that looks accidental. Scoping
the songs `show` breaks 6 tests until that fixture is flipped to `3`. With the flip applied, the
**full suite is green: 8,199 runs, 164,699 assertions, 0 failures, 0 errors.** The fixture is
referenced by `ranked_lists.yml`, `list_items.yml`, `list_penalties.yml`, `ai_chats.yml` and eight
test files, and none of them depend on its status. Books and games need no fixture change — both
already scope `show` to `:active`, and `Games::ListsControllerTest` already carries a
"show 404s for a non-active list" test that is the template for the music ones.

## Data model

One migration on `lists`. No new table.

```
submitted_at     datetime, null    -- set ONLY by the public form; null = admin-created
submitter_email  string,   null    -- optional, anonymous submitters only
submitter_ip     string,   null    -- spam triage only, matches corrections.submitter_ip

index on submitted_at
```

`submitted_at` is the marker that makes the admin filter possible. `submitted_by_id` cannot do it
alone: 1,721 of the 1,772 unapproved lists have no submitter and almost all of those are import
backlog, so "unapproved" and "submitted" are not the same set.

Backfill: `submitted_at = created_at WHERE submitted_by_id IS NOT NULL`. A no-op in production — all
209 such rows are `Books::List` and books data exists only in development — and in dev it correctly
surfaces the migrated legacy submissions.

### No length validations on `List`

Production `raw_content` reaches **1,568,804 characters** (p95 217,384; 35 of 246 rows exceed
100,000). Those are admin-pasted page HTML feeding the wizard. A model-level cap would break the
admin paste path, so **caps are enforced in the submission service** and admin paths are untouched.

### No uniqueness index on `url`

22 duplicate `(type, url)` pairs already exist. A unique index would fail to apply. The duplicate
check is a soft check at submission time only.

## Deferring the Nokogiri parse

`List#should_simplify_content?` is `raw_content.present? && (new_record? || raw_content_changed?)`,
so **every** public submission carrying pasted content would run
`Services::Html::SimplifierService` — a Nokogiri parse — synchronously inside the request. On an
anonymous endpoint that is a CPU lever.

An `attr_accessor :skip_content_simplification` guards the callback; the submission service sets it.

This is safe because the wizard recomputes it unconditionally: `Services::Lists::ImportService` does
`simplified_content = Services::Html::SimplifierService.call(@list.raw_content)` followed by
`@list.update!(simplified_content:)` before parsing. Nothing downstream depends on the value being
present at insert time.

## Type resolution

`Services::Lists::SubmissionRegistry` maps the current domain to the list classes that may be
submitted there, mirroring `Services::Corrections::TypeRegistry`:

| Domain | List type(s) | Type picker |
|---|---|---|
| books | `Books::List` | not shown |
| games | `Games::List` | not shown |
| music | `Music::Albums::List`, `Music::Songs::List` | shown (radio) |

The submitted type param is validated against the current domain's entry. **Never `constantize`** —
legacy's `params[:changeable_type].constantize` is the anti-pattern this avoids. An unrecognised type
is a 400. The registry also drives whether the form renders a picker, so the form cannot drift from
the allowlist.

## Routes

Defined inside each domain's own `DomainConstraint` block — three near-identical stanzas, the same
shape corrections uses, which gives clean per-domain helpers rather than one name that has to work
across four sites.

The two **cacheable GETs** are per-domain, so each site gets its own helper and its own cache key:

```ruby
# inside the books constraint; games and music are analogous
get "lists/new",    to: "list_submissions#new",    as: :new_books_list_submission,
    constraints: {format: /html/}
get "lists/thanks", to: "list_submissions#thanks", as: :books_list_submission_thanks,
    constraints: {format: /html/}
```

Two things carried over verbatim from the corrections routes, both load-bearing for the same reason:

- **Not inside the `(/rc/:ranking_configuration_id)` scope.** `ListSubmissionsController` never calls
  `load_ranking_configuration`, so an rc-prefixed URL would render 200 for *any* value of that
  segment — every value a distinct Cloudflare cache key, every one a MISS, every one a full render at
  origin. That is the legacy flood reproduced with one extra path segment, and a Cache Rule that
  normalises query strings cannot see a path segment at all. Leaving the scope off means the router
  rejects those URLs before a controller, view or database connection is involved.
- **`constraints: {format: /html/}`** closes the same axis on `(.:format)`: `.json`, `.foo` and so on
  are each another cache key.

The **POST is a single global route**, exactly as `resources :corrections, only: [:create]` is:

```ruby
post "list_submissions", to: "list_submissions#create", as: :list_submissions
```

It needs no per-domain variant — it is never cached, and the domain comes from the host through
`Current.domain` regardless. One route means one place the honeypot, rate limits and registry
validation are wired.

Two route repairs are required:

- **games**: `get "lists/:id", to: "games/lists#show"` has no id constraint, so `/lists/new` and
  `/lists/thanks` would resolve to `show` with `id: "new"`. Add `constraints: {id: /\d+/}`, matching
  books. This is a latent bug independent of this feature.
- **music**: `resources :lists, only: [:index, :new, :create]` drops to `only: [:index]`.

Books needs no repair: its `get "lists/:id"` is already constrained to `/\d+/`, and none of its seven
legacy `lists/*` 301s match `new` or `thanks`.

`robots.txt` gains `Disallow: /lists/new` and `Disallow: /lists/thanks`.

## Controller

`ListSubmissionsController`, following `CorrectionsController` closely enough that the two can be
read side by side.

```ruby
include Cacheable
include VisitorIp
layout :domain_layout                    # "#{Current.domain}/application", as CorrectionsController

protect_from_forgery with: :null_session, only: [:create]

before_action :set_submittable_types     # registry -> the classes this domain allows
before_action :set_list_class, only: [:create]   # validates the submitted type against them, 400 otherwise
before_action :cache_for_show_page, only: [:new, :thanks]
before_action :prevent_caching,     only: [:create]
```

Two filters, not one, because `new` and the rate-limit re-render need the whole allowed set (music
renders a picker over two types) while `create` needs the single resolved class.

`@indexable = false` on `new` and `thanks` — load-bearing on music and games, whose helper renders
`index, follow` unless it is explicitly false.

### Caching the form, and the CSRF consequence

The form page is edge-cached like the corrections form. That removes the flood vector legacy's
uncached public form left open, at the cost of the token dance: a cached page's
`<meta name="csrf-token">` belongs to whoever populated the cache.

`CorrectionTokenController` already solves this and does no database work, so it is renamed
`FormTokenController` and serves both `/correction_token` (kept, so already-cached corrections pages
keep working) and `/form_token`. Its Stimulus controller is generalised alongside it and fetches on
**first interaction with the form**, not on load, so a crawler that never touches the form never
reaches the endpoint.

`null_session` is the second layer: if that fetch never happened — JS off, blocked, slow — the POST
is accepted as an anonymous submission rather than raising a 422 the submitter cannot act on. What
lands is a submission the attacker could have posted directly, and it is moderated before it is
visible anywhere.

**Full effectiveness needs a Cloudflare Cache Rule ignoring query strings on `/lists/new`.** Without
it, `?x=1`, `?x=2` … are distinct cache keys and every request misses through to Rails. Lower
priority than the corrections rule was: that form is linked from 156k book pages, this one from three
list index pages.

### Rate limits

Two buckets, sized from the legacy data above rather than guessed.

```ruby
SIGNED_IN_RATE = 30   # one contributor submitted 25 in a single day
ANONYMOUS_RATE = 10
RATE_WINDOW    = 1.hour
```

- `by:` goes through `visitor_ip`, **never `request.remote_ip`** — in production that is the
  Cloudflare edge IP, so keying on it puts every visitor in one bucket and throttles the whole site.
- `with:` renders the form again with an `@error`; it never redirects (the redirect target is
  edge-cached, so a flash would never be read) and never uses Rails' default raise, which renders an
  HTML error body.
- Both declared **after** `set_submittable_types`. Filter order is load-bearing: `rate_limit`
  installs its own `before_action`, so the types must already be resolved when the `with:` lambda
  re-renders the form. Declare either above that filter and a throttled request raises
  `NoMethodError` on nil instead of showing the rate-limit message.

### Honeypot

A hidden `website` field. Filled means accept-and-discard, returning **the same redirect as a real
success** — a 200 stops a bot retrying, where a 422 or a different destination teaches it the
submission was dropped.

## The form

Always visible:

- List type picker — **music only**, driven by the registry
- **Name** (required)
- Source / publication
- URL
- Description
- "Paste the list items" (`raw_content`)
- Your email — optional, **always rendered**; see below
- Hidden honeypot

**The email field is always rendered, for everyone.** The form page is edge-cached with the session
skipped, so `current_user` is nil while it renders and the HTML is identical for every visitor —
per-user state on an edge-cached page has to be hydrated from an uncached endpoint, never branched on
at render time. A `<% if current_user %>` here would not merely fail to help; it would bake one
visitor's state into the copy every other visitor is served. `#create` ignores the submitted address
whenever `current_user` is present, because the account address is the better reply channel.

Collapsed behind a `<details>` element labelled "More detail (optional)": year published, number of
voters, years covered, and the six characteristic checkboxes (location specific, category specific,
yearly award, voter count estimated, voter names unknown, voter count unknown).

`<details>` rather than a checkbox-driven panel on purpose: Turbo caches checkbox checkedness and
restores such panels open on Back. These fields are behind a disclosure because they feed ranking
weight and most visitors have no reliable way to know them — but the top three submitters produced
179 of 209 legacy submissions and do know them, so they stay reachable.

Entry point: a button on each domain's `/lists` index page, where music already puts one. Not the
footer, not the main nav — music and games still duplicate their nav markup inline.

## Submission service

`Services::Lists::Submission.call(list_class:, params:, user:, submitter_email:, submitter_ip:)`
returning the repo's standard `Result`.

Caps, enforced here rather than on the model:

| Field | Cap |
|---|---|
| `name` | 255 |
| `source` | 255 |
| `url` | 2,000 |
| `description` | 5,000 |
| `raw_content` | 100,000 |
| `submitter_email` | 255 |

**Duplicate check:** a list of the same `type` whose URL normalises to the same value, in **any**
status, returns a distinct failure and no row is created. The controller renders it as "we already
have this one" rather than a validation error. Scoped by `type` because the same page can
legitimately back both an albums and a songs list.

Normalisation, applied to both sides of the comparison: strip surrounding whitespace, downcase the
scheme and host, drop the scheme entirely, drop a leading `www.`, drop a trailing slash. Query string
and fragment are kept — they routinely distinguish real pages. Comparison is done in Ruby against a
narrowed candidate set (same `type`, matching host), not with SQL string functions, so the rules live
in one readable place and are directly unit-testable.

Blank URLs skip the check entirely: a list with no online source is legitimate, and 22 duplicate
`(type, url)` pairs already exist, so this is a courtesy to the submitter, not an invariant.

On success the record is built with `status: :unapproved`, `submitted_at: Time.current`,
`submitted_by: user`, `submitter_email`, `submitter_ip`, and `skip_content_simplification = true`.

The controller then fires `AdminMailer.new_list_submission(list).deliver_later` — a near-copy of
`new_correction`, resolving the domain through the registry for branding, with `reply_to` falling
back from the account email to the submitted one — and redirects to the static `thanks` page.
`deliver_later`, not `deliver_now`: legacy built and sent this inline and blocked the submitter on
SendGrid with no retry.

**A thanks page, not a flash.** Public layouts render no flash, which is why music's current
confirmation has never been seen.

## Admin

No new page. `Admin::ListsBaseController` gains a second filter beside the existing status dropdown —
All / User submitted / Added by admin — reading `submitted_at`. This matters because filtering the
existing page by "Unapproved" returns 1,772 rows, almost all of it import backlog.

`Admin::Lists::TableComponent` gains a submitter column: the account email, else the submitted email,
else "Anonymous". `Admin::Lists::ShowComponent` already renders `submitted_by.email` and gains the
`submitter_email` fallback.

Approving is unchanged: the queue links to the list's existing admin edit page and wizard, where
status and ranking configuration are set today. No second way to do the same thing.

## Testing

- Controller tests per domain: anonymous and signed-in submission, honeypot discard, both rate-limit
  buckets, duplicate URL, each cap, unknown type → 400, `thanks` renders.
- Service tests: caps, duplicate detection and its URL normalisation, `skip_content_simplification`,
  the fields it stamps.
- Mailer test for `new_list_submission`, including the `reply_to` fallback chain.
- Admin filter tests.
- **Regression tests pinning the music status scoping** — an unapproved music list must 404 on
  `show` and be absent from `index`.
- A Playwright E2E test for the submit flow.
- Deleted alongside music's `new`/`create`: its 11 existing controller tests, including the one
  asserting on a `flash[:notice]` nobody can see.

## Increments

1. **Close the music list-show leak** — status scoping on `show` and `index`, `nofollow` on source
   links, regression tests. Ships independently and first.
2. **Shared machinery, wired to books** — migration, registry, submission service, controller,
   routes, form, `FormTokenController` generalisation, admin mailer, thanks page.
3. **Games and music** — wire both; delete `Music::ListsController#new/#create`, its views and tests.
4. **Admin** — the user-submitted filter and submitter columns.
5. **Finish** — Playwright E2E, `robots.txt`, `docs/features/` documentation.
