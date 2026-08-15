# Reviews admin — view, delete, and a user's review history

Extends the admin reviews surface shipped in reviews increment 5
(`2026-08-13-my-reviews-design.md`, PR #225) with a per-review detail page and a reviews card on
`/admin/users/:id`, and lifts the list view out of the books folder so the other domains cost
four lines each when reviews are enabled for them.

## Why

Three gaps in what shipped:

1. The list truncates a review to 80 characters. A moderator deciding whether a 2,000-word review
   is abusive has nowhere to read it.
2. `/admin/users/:id` counts ranking configurations, penalties, AI chats, submitted lists, external
   links and domain roles — but not reviews. "Is this account a spammer?" is unanswerable from the
   user page.
3. Reviews exist only for books today and will be enabled for music and games. The controller
   (`Admin::ReviewsBaseController`) was deliberately written domain-generic; the *view* was not.

## Scope

**In:** a shared list view, a per-review detail page, a reviews card on the admin user page.

**Out:** editing reviews. Admins view and delete only.

Editing was considered and rejected. Ratings feed `Services::Reviews::SummaryRecalculator` and the
public histogram, so an admin editing a rating silently rewrites a book's average; editing body text
is putting words in a reader's mouth. A review that is bad enough to change is bad enough to delete.

**Unchanged:** `/admin/reviews` already sorts newest-first (`order(created_at: :desc, id: :desc)`),
already searches reviewer email/display name and book title/author, and already has the Written/All
toggle and per-row Delete. None of that is touched.

## Increment 1 — shared views

### Move

`app/views/admin/books/reviews/index.html.erb` → `app/views/admin/reviews_base/index.html.erb`

The directory is `reviews_base`, not `reviews`. Rails builds a controller's view-lookup prefixes from
its own `controller_path` plus each ancestor's, and the ancestor here is
`Admin::ReviewsBaseController` whose `controller_path` is `admin/reviews_base`. Verified directly:

```
Admin::Books::ReviewsController._prefixes
# => ["admin/books/reviews", "admin/reviews_base", "admin/base", "application"]
```

So a template at `app/views/admin/reviews_base/index.html.erb` is found automatically by every
present and future subclass — no `render` call, no `local_prefixes` override, no config. The
alternative (override `local_prefixes` to return `["admin/reviews"]` and get a nicer directory name)
was rejected: it buys a cosmetic rename in exchange for a Rails hook a reader has to know about, and
`reviews_base` matches the name of the controller that actually renders it.

The books-specific `app/views/admin/books/reviews/` directory is deleted, not left as an override.

### Per-domain seams

The moved view hardcodes `admin_books_reviews_path`, `admin_books_review_path` and a "Book" column
header. `Admin::ReviewsBaseController` grows three `helper_method`s, each `raise NotImplementedError`
in the base and filled in by the subclass — the same shape the existing `reviewable_class` /
`reviewable_includes` / `reviews_index_path` triple already uses.

| helper | `Admin::Books::ReviewsController` returns |
| --- | --- |
| `reviews_index_path` | `admin_books_reviews_path` *(exists; add to `helper_method`)* |
| `review_detail_path(review)` | `admin_books_review_path(review)` |
| `reviewable_label` | `"Book"` |

`review_detail_path`, **not** `review_path`. The global route helper `review_path` already names the
public `PATCH /reviews/:id` endpoint (routes.rb line 270). This is the identical shadowing trap the
base controller already documents for `reviews_index_path` vs. the public `POST /reviews`
`reviews_path`, and the same reasoning applies.

`reviewable_label` is a plain string on the controller, not a method on the reviewable model: it
titles a table column in one specific admin table, which is not a property of a book.

### Adding a domain later

With this in place, enabling the admin surface for music is:

1. `Reviews::Registry::DOMAIN_TYPES` gains `"music" => ["Music::Album"]`
2. `Admin::Music::ReviewsController < Admin::ReviewsBaseController` — five lines
3. `resources :reviews, only: [:index, :show, :destroy]` in the music admin namespace
4. A `{label: "Reviews", icon: :star, ...}` entry in `Admin::DomainNav::CONFIGS[:music][:items]`

Nothing music- or games-facing ships in this work. A reviews page for a domain whose public review
widget is off would be a permanently empty table behind a live sidebar link.

`Music::Album` and `Games::Game` both expose `title`, exactly like `Books::Book`, so the shared view
needs no per-domain body logic. Search is already delegated per-domain through
`reviewable_class.review_text_search(scope, term)`, which each reviewable defines for itself.

## Increment 2 — the detail page

### Controller

`Admin::ReviewsBaseController#show`:

```ruby
@review = Review.where(reviewable_type: reviewable_class.name).find(params[:id])
```

Scoped to `reviewable_type`, **not** a bare `Review.find` — the same reasoning `destroy` already
carries. `authenticate_admin!` proves access to the domain this controller is mounted under; without
the scope a books-only editor could read a music review by guessing an id. A foreign id raises
`RecordNotFound`, which the admin layer already renders as a 404.

`show` is a read, so it is deliberately **not** added to the `require_domain_write!` `only:` list —
a read-only domain viewer can open a review but the Delete button's `destroy` still 403s for them.

### Route

```ruby
resources :reviews, only: [:index, :show, :destroy]
```

in the books admin namespace (routes.rb line 435), replacing `only: [:index, :destroy]`.

### View — `app/views/admin/reviews_base/show.html.erb`

- Back link to `reviews_index_path`, and a Delete button (`button_to`, `turbo_confirm`) that on
  success redirects to the list with a notice — the existing `destroy` already does exactly this.
- Stars via `Reviews::StarsComponent`, the review title, and the review body.
- Reviewer email, linked to `admin_user_path(review.user)`. That route is in the global admin
  namespace and answers on every host, so a plain path is correct here.
- The reviewable's title, linked to its admin record via the existing
  `Admin::DomainRouting.path_for(review.reviewable)` — `ENTITIES` already maps `"Books::Book"` to
  `admin_books_book_path`. Same-domain, so a plain path is correct here too.
- Exact `created_at` / `updated_at`, and the review id.

### Body rendering and spoilers

The body renders through `Services::Reviews::BodySanitizer.render(review.body)` inside a wrapper
carrying `class="review-body"` and `data-controller="reviews--spoiler"`.

Spoilers blur and reveal on click, identical to the public book page. This is a decision, not an
accident: `books/reviews.css` is imported by `books/application.css`, which the admin layout loads
via `chrome[:stylesheet]`. **Omitting the Stimulus controller would leave spoiler passages blurred
with no way to unblur them** — the CSS blurs `.review-spoiler` unconditionally and only the
controller adds `.review-spoiler--revealed`. `Reviews__SpoilerController` is registered in the shared
`app/javascript/controllers/index.js`, which `application.js` imports, which the admin layout loads —
so no bundling change is required. Verified.

`Reviews::ReviewComponent` is **not** reused. It deliberately shows no author and renders relative
time ("3 days ago"); the admin page needs the reviewer and exact timestamps, and constraining the
public component to serve both would couple two surfaces that should be free to diverge.

### List → detail

The truncated review-text cell in the list becomes a link to `review_detail_path(review)`. The
per-row Delete button stays, so moderating a run of obvious spam does not get slower.

## Increment 3 — reviews on the admin user page

### Controller

`Admin::UsersController#show` loads:

```ruby
@reviews = @user.reviews.recent.includes(:reviewable).limit(10)
@reviews_count = @user.reviews.count
```

`Review.recent` is the existing model scope (`order(created_at: :desc, id: :desc)`). The
`user_id, created_at` index already covers this.

`includes(:reviewable)` is load-bearing, not decorative: the card renders `review.reviewable.title`
in a loop, which is a textbook N+1 without it.

### View

A "Reviews" card in the left column of `app/views/admin/users/show.html.erb`, alongside Profile
Information / Authentication Details / Activity. Each row: reviewable title, rating, a short snippet
(`review.title.presence || review.body&.truncate(80)`, matching the list), and the date. Footer reads
"Showing 10 of 47" when there are more than 10.

A `Reviews` count is also added to the Related Data panel next to Penalties and AI Chats.

### The hostname trap

`resources :users` sits in the **global** `namespace :admin` (routes.rb line 726) with no
`DomainConstraint`, so `/admin/users/482` answers on all four hostnames. `/admin/reviews` lives
inside `constraints DomainConstraint.new(config.domains[:books])` (line 378) and routes on the books
host only.

A path-only link from the user page therefore breaks whenever an admin is browsing on the music or
games host: `admin_books_review_path(r)` generates `/admin/reviews/123`, which does not route there.

So the card's links are **absolute URLs carrying the target domain's host**, derived from the
review's own reviewable:

```ruby
domain = Admin::DomainRouting.domain_for(review.reviewable)   # => :books
host   = Rails.application.config.domains[domain]             # => "dev-new.thegreatestbooks.org"
```

This is the first cross-domain link in the admin, so it goes in a small helper rather than being
open-coded in the view — every domain added later needs the same treatment, and the failure is
invisible in development where every host resolves to localhost.

If a review's `reviewable_type` is not in `Admin::DomainRouting::ENTITIES`, the row renders unlinked
rather than raising. A user page must not 500 because of one unmapped review.

## Testing

Minitest + fixtures + Mocha, mirroring the app namespaces.

**`test/controllers/admin/books/reviews_controller_test.rb`** (extend the existing file)

- `show` returns 200 for a books review.
- `show` on a review whose `reviewable_type` is not `Books::Book` raises `ActiveRecord::RecordNotFound`.
- A user with read-only books domain access can `show` but is redirected on `destroy`.

Not asserted here: that the list markup links each row to the detail page. Controller tests assert
status codes and params, never HTML — the click-through is the Playwright test's job.

**`test/controllers/admin/users_controller_test.rb`** (extend)

- `show` renders for a user with reviews and for a user with none.
- `assert_queries_count` pinning the preload, so dropping `includes(:reviewable)` fails the suite
  rather than quietly costing 10 queries per user page.
- The rendered review links are absolute and carry the books host. Assert on the generated URL, not
  on markup. This is the one assertion guarding a defect that is invisible locally, and it is the
  reason it is worth asserting on a URL despite the "controller tests assert behavior, not HTML"
  rule — it is testing a route/host decision, not presentation.

**Fixtures:** `test/fixtures/reviews.yml` already exists from increment 5. Check the actual fixture
names before referencing them. Do **not** run `create_fixtures` — it truncates.

**Playwright** (`web-app/e2e/tests/`)

- Admin opens `/admin/reviews`, clicks into a review, reads the full body, deletes it, lands back on
  the list with the row gone.
- Admin opens a user with reviews and sees the Reviews card.

The e2e admin user needs its role intact (`bin/rails e2e:admin` if specs time out on the public
homepage).

## Gates

`bin/rails test` and `bundle exec standardrb` both clean. `test/lint/daisyui_v4_classes_test.rb`
must stay green — the new views use `fieldset`/`label`/bare `input`, never the ten removed classes.
No brakeman.

## Deliberately not doing

- **Editing reviews** — see Scope.
- **An approval queue** — nothing gates publishing; this is post-hoc moderation.
- **Bulk delete** — no evidence of need; the per-row button already handles a run of spam.
- **A per-user filter on the reviews list** — the user page is that view, and the list is per-domain
  while the user page is not, so a "see all" link would need one link per domain.
- **Music and games wiring** — see Increment 1.
