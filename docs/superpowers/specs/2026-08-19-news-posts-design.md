# News posts

Replaces the legacy books blog with a news section on all three sites — books, music and games —
storing posts as Markdown, adding admin-managed topics, share-card metadata and an RSS feed, and
migrating the 31 existing books posts.

## Why

The legacy blog is where site news goes: ranking refreshes, new lists, feature launches. It works,
but it is the oldest and least developed corner of the legacy app, and music and games have no
equivalent at all — so a feature ships on those sites with nowhere to announce it.

Three things are wrong with the legacy version beyond its age:

- **No categorisation.** A `tags` string array exists and is empty on all 31 posts.
- **No structure worth having.** A `Blog` container model with exactly one row, and two boolean
  flags where one is dead and the other has never been set.
- **Nothing for sharing.** No Open Graph tags, no feed, no summary field — a link to a post pasted
  into Discord or Twitter renders as a bare URL.

The eventual goal is automatic posting to Twitter and Facebook. That is **not** in this project,
but it shapes two decisions here: the content is stored as Markdown rather than HTML because
Markdown converts to a plain-text social post cleanly, and the RSS feed exists partly because
Zapier/IFTTT/Buffer can drive social posting off a feed with no code at all.

## What the legacy implementation actually does

Two models in `../the-greatest-books/admin`: `Blog` (`app/models/blog.rb`) and `BlogPost`
(`app/models/blog_post.rb`). `Blog` has a `create_default`/`default` pair and is the parent of
every post. `BlogPost` uses `friendly_id` on the title and `has_rich_text :content` (ActionText).

Public surface is `BlogsController#show` at `/news` — which renders pinned posts, then the rest,
each with its **full body inline** — and `BlogPostsController#show` at `/blog_posts/:slug`.

### Measurements against the legacy database

Run against `the_greatest_books_legacy` on 2026-08-19:

| Fact | Value |
| --- | --- |
| Posts | 31 |
| `blogs` rows | 1, titled "Default" |
| Distinct authors | 1 (`user_id` 1141) |
| `active: true` | 31 of 31 |
| `front_page: true` | 27 of 31 |
| `pinned: true` | **0 of 31** |
| Posts with non-empty `tags` | **0 of 31** |
| Body length | 40 – 2,060 characters |
| Bodies containing `<img>` | 0 |
| Bodies containing `<action-text-attachment>` | 0 |

The complete HTML tag vocabulary across all 31 bodies is **eight tags**: `a, br, strong, h1, ul,
ol, li, div`. All 31 use `<div>` (Trix's paragraph wrapper), 8 contain a list, 5 contain a link,
and exactly 1 contains an `<h1>`.

`blog_posts.id` skips 26, so a post was deleted at some point; its rich text row is gone too.

### What the flags actually do

- `front_page` is **read by nothing**. `BlogPost` defines the scope, `_form.html.erb` renders the
  checkbox, `_blog_post.html.erb` displays the value — and no view or controller anywhere calls
  `BlogPost.front_page`. It was for a homepage strip that was never built.
- `pinned` *is* honoured by `BlogsController#show`, which renders pinned posts above the rest. No
  post has ever been pinned.
- `tags` is permitted in `blog_post_params` and never rendered or queried.

## Decisions

### Markdown source, HTML at render time

`news_posts.body` stores exactly what was typed. HTML is generated on read by
`Services::News::BodyRenderer`. Nothing transforms the body on write.

This is the `idempotent-write-paths` rule that the reviews feature arrived at after a write-time
sanitizer was fed its own output and destroyed the markup it had generated. Markdown gets that
property for free rather than requiring a parser-based inverse.

ActionText was the alternative and is rejected: it is not installed in this app (no
`action_text_rich_texts` table), installing the engine into an app with **no Rails asset pipeline**
means hand-wiring Trix's CSS and JS through Rollup and Tailwind, Trix's formatting is limited (no
headings past `h1`, no code blocks, no tables), and stored Trix HTML is awkward to convert into a
tweet.

`commonmarker` (2.9.0) is the one new runtime gem; it ships a precompiled `x86_64-linux` platform
gem, so no Rust toolchain is needed in the build image. Nokogiri and `rails-html-sanitizer` are
already in the lockfile.

### One site per post

A post belongs to exactly one of books / music / games via a `domain` enum. A cross-site
announcement is written once per site. At roughly fifteen posts a year that is cheap, and it avoids
a join table, a canonical-URL problem (the same post reachable at three URLs), and the "which
account posts it?" question when social posting lands.

### Global namespace, no STI

`NewsPost`, `NewsTopic` and `NewsPostTopic` live in the global namespace alongside `Review`,
`Description` and `Image`. CLAUDE.md's "namespace all media code" rule does not bind — a news post
is site content, not media data, exactly as a `Review` is.

STI per domain (the `List` / `Category` pattern) is rejected because `List` earns STI by having
per-domain *contents* — a `Books::List` holds books. A news post is byte-identical on every site,
so subclasses would be three empty model files and three empty test files, and every query would
carry `type` for no benefit.

### Drafts never render on a public URL

The public scope is `published_at <= Time.current`; anything else 404s. There is no "logged-in
admin sees drafts" branch on a route Cloudflare caches for 6–24 hours. Preview lives in admin,
where `Admin::BaseController` already forces `no-store`. This makes the cache-poisoning class
unrepresentable rather than something to manage.

## Domain model

Three new tables. Migration names are assigned at implementation.

### `news_posts`

| Column | Type | Notes |
| --- | --- | --- |
| `domain` | integer, not null | enum; mirrors `DomainRole`'s mapping exactly so the two cannot drift |
| `title` | string, not null | |
| `slug` | string, not null | `friendly_id`, scoped to `domain` |
| `body` | text, not null | Markdown source, stored verbatim |
| `summary` | text | optional; index cards, meta description, RSS |
| `published_at` | datetime | `nil` = draft |
| `user_id` | bigint, not null | FK to `users` |

Indexes: `(domain, published_at DESC)`; unique `(domain, slug)`.

Attachments: `has_one_attached :share_image` (1200×630 variant for link previews) and
`has_many_attached :body_images`.

`Image` is deliberately **not** reused. Its variants cap at 250×250 with `preprocessed: true` —
sized for cover thumbnails — and widening them would touch every book cover and album art record in
the app. Its `primary` / `parent` semantics are also a poor fit for "the picture that represents
this post when shared".

### `news_topics`

| Column | Type | Notes |
| --- | --- | --- |
| `domain` | integer, not null | same enum |
| `name` | string, not null | |
| `slug` | string, not null | `friendly_id`, scoped to `domain` |

Unique index `(domain, slug)`.

Topics are per-domain, matching `Category`'s per-domain split, so each site's admin form offers
only its own vocabulary. Creating "Rankings" three times is a one-off cost paid once.

### `news_post_topics`

Join table: `news_post_id`, `news_topic_id`, unique index on the pair.

Slug scoping follows `Category` (`app/models/category.rb:37`), which uses
`friendly_id :name, use: [:slugged, :scoped, :finders], scope: :type`. Here the scope is `domain`,
so books and music can each hold a `december-update`.

## Content pipeline

`Services::News::BodyRenderer` in `app/lib/services/news/` takes a Markdown string and returns
sanitized HTML. Two layers, because they fail differently:

1. `commonmarker` with `unsafe: false` — raw HTML in the source is escaped, not emitted.
2. `Rails::HTML5::SafeListSanitizer` with an explicit tag allowlist, as defence in depth.

Allowlist: `p, br, a, em, strong, ul, ol, li, blockquote, h2, h3, h4, code, pre, hr, img`.
Attributes: `href, title, src, alt`.

### Heading shift

`#` renders as `<h2>`, `##` as `<h3>`, `###` and deeper as `<h4>`. The page title is already the
page's `<h1>`; a second one is an accessibility and SEO defect.

This happens at **render**, not on save, so it is a display rule and not a data mutation — the
stored source keeps whatever the author typed. The one legacy post with a mid-body `<h1>` lands
correctly under this without special handling.

Excluding `h1` from the allowlist instead is rejected: the sanitizer would unwrap the tag, leaving
the text with its formatting silently gone.

### Summary fallback

`summary` is optional. When absent, meta descriptions and RSS descriptions derive plain text from
the rendered body by walking block boundaries and inserting separators — **not** by calling `.text`
on the fragment, which concatenates lines and drops `<br>`.

## Public surface

`/news` is declared in the **global** (non-domain-constrained) route section alongside
`/membership`, `/my/lists` and `/searches`. One controller, one set of views, one set of route
helpers, serving all three hosts; `DomainLayout#resolve_layout` picks the layout from
`Current.domain` at request time.

| Verb | Path | Purpose | Auth | Cache |
| --- | --- | --- | --- | --- |
| GET | `/news` | Index, newest published first | public | `cache_for_index_page` (6h) |
| GET | `/news/page/:page` | Paginated index | public | 6h |
| GET | `/news/topic/:slug` | Posts carrying one topic | public | 6h |
| GET | `/news/topic/:slug/page/:page` | Paginated topic | public | 6h |
| GET | `/news.rss` | Feed (format on the index route) | public | 6h |
| GET | `/news/:slug` | One post | public | `cache_for_show_page` (24h) |

Source of truth is `config/routes.rb`. Pagination uses `pagy_path`, following the pattern already
solved for books lists and authors — including the pagy-43 path-based paging caveats and the fact
that every domain's `paging.css` still targets dead pagy-9 selectors.

`topic` is added to `friendly_id`'s reserved words (`config/initializers/friendly_id.rb:19`) so no
post can claim `/news/topic`, and the topic route is declared before the slug route regardless.

Format is constrained to `html` and `rss`.

### Cache invalidation

Every public news page is edge-cached (6h index, 24h show), and nothing about a write reaches
Cloudflare on its own. So `Admin::NewsPostsBaseController` enqueues
`News::PurgeCachedPagesJob` explicitly from `#create`, `#update` and `#destroy` — never from a
model callback, which would also fire from the data migration and from every test that creates a
post. `Services::News::CachedUrls` builds the URL set; the job purges it via
`Cloudflare::PurgeService#purge_urls`, in batches of 100 (Cloudflare's per-request cap on this
plan), and never raises — a failed purge degrades to the page staying cached until it expires.

What one write purges, for the post's domain only:

| URL | Why |
| --- | --- |
| `/news/:slug` | the post itself |
| `/news`, `/news/page/2..n` | the index sorts `published_at DESC`, so any write shifts every page |
| `/news/topic/:slug` (+ pages), for **every** topic of that domain | an update can change topic membership, and the old set is unrecoverable once `assign_attributes` has run |

Purged for every host in the domain's `config.domains` entry, which may be a comma-separated list —
Cloudflare keys its cache by host, and `detect_current_domain` treats each entry as a live serving
host. This differs deliberately from `MailBranding` and `MembershipController`, which take `.first`
because they must name exactly one canonical host.

Every write purges, with no `published?` gate: a wrong gate means a published post that never
purges, while a needless purge costs a few origin re-renders. That also covers unpublishing, which
is the worst case — without it a retracted post stays publicly readable for 24 hours.

Not covered, deliberately: query-string variants (`/news?utm_source=x` is its own cache entry and
cannot be enumerated); the legacy `/blog_posts/*` routes (301s, not content); the bulk data
migration (creates rows directly, and a full-zone purge is the right tool for a one-off import); and
**news topic** create/update/delete, which changes the name shown on `/news/topic/:slug` and on every
post page listing it. Post writes are what this covers.

**Increment 5 must extend it:** `/news.rss` is a seventh cached URL and belongs in
`Services::News::CachedUrls` when the feed lands.

### Legacy redirects

`/news` is already the legacy index path and carries over unchanged — no redirect, no lost links.
Declared **inside the books domain constraint**, since only books has a legacy history:

| Legacy | New |
| --- | --- |
| `/blog_posts` | 301 → `/news` |
| `/blog_posts/:slug` | 301 → `/news/:slug` |

### Share cards

There are currently **no Open Graph or Twitter meta tags anywhere in this app**. The books layout
gains `og:title`, `og:description`, `og:image`, `og:type` and `twitter:card`, driven by
`content_for` and defaulting to site-level values, so every existing books page renders exactly as
it does now. Music and games get the same in increment 6.

## Admin surface

One shared controller pair — `Admin::NewsPostsController` and `Admin::NewsTopicsController`, both
`include Admin::DomainScopedAuth` — reached from each domain's admin namespace via
`controller: "/admin/news_posts"`. This is the indirection `Admin::ImagesController` already uses
(`config/routes.rb`, `resources :images, only: [:index, :create], controller: "/admin/images"`).

Read actions gate on `authenticate_admin!`; every mutating action gates on `require_domain_write!`,
matching the shared-controller write-gating already applied to images and category items.

Each domain gains a "News" entry in `Admin::DomainNav::CONFIGS`
(`app/lib/admin/domain_nav.rb`) — a config-only change.

The post form carries title, body (textarea), summary, topics (checkboxes), publish date, share
image, and a body-image uploader that returns the Markdown snippet to paste (`![alt](url)`).

### Preview is server-rendered

Preview posts the textarea content and swaps a Turbo Frame, with a small Stimulus controller
debouncing the refresh. It renders through the same `BodyRenderer` the public page uses, so the two
cannot drift.

A client-side Markdown library is **not** an option here: admin and public still share
`application.js`, so it would be downloaded by every visitor to every site to serve one admin
screen. See "Out of scope" below.

## Migration

New `LegacyBooks::BlogPost` and `LegacyBooks::RichText` on the existing `LegacyBooks::Record` base,
plus `Services::BooksMigration::NewsPostMigrator` and a `data_migration:news_posts` rake task,
following the ~25 migrators already in `app/lib/services/books_migration/`.

| Legacy | New | Notes |
| --- | --- | --- |
| `title` | `title` | verbatim |
| `slug` | `slug` | **verbatim**, including the collision-suffixed `added-5-new-lists-d0171449-…` |
| `content` (ActionText HTML) | `body` (Markdown) | converted, see below |
| `created_at` | `published_at` and `created_at` | correct for all 31, since all are `active: true` |
| `user_id` 1141 | `user_id` 1141 | already present in the new app with the admin role; ids were preserved by `UserMigrator` |
| — | `domain` | `:books` |
| `front_page` | *dropped* | read by nothing |
| `pinned` | *dropped* | never set on any post |
| `tags` | *dropped* | empty on all 31 |
| `Blog` "Default" | *dropped* | one row whose only job is to be a parent |

### HTML → Markdown

Uses the `reverse_markdown` gem (3.0.2), needed only for this one-time lift and removable once the
production run is done. The corpus is eight tags, comfortably inside what it handles, and
it is less code and less risk than hand-rolling Nokogiri. The failure mode to watch is spacing:
Trix wraps paragraphs in `<div>` and separates them with `<br><br>`, which is exactly where a
converter mangles output while still producing valid Markdown.

The converted Markdown becomes the source of truth and will be hand-edited from here on, so it gets
two checks:

1. **A round-trip assertion over all 31 posts.** Render the produced Markdown back through
   `BodyRenderer` and compare normalised text content against the legacy HTML's text content.
   Catches silently dropped content. 31 is small enough to assert on every post rather than sample.
2. **A human read of all 31.** The migrator dumps before/after to a file. Average body is ~500
   characters; this is the only way to catch spacing that is technically valid and reads wrong.

### Topics

No legacy data exists, so posts arrive untagged and topics are assigned by hand in admin
afterwards. Guessing from title keywords was considered — the titles are regular enough that it
would mostly work — and rejected: "mostly" on a one-time job that gets reviewed by hand anyway is
not worth the code. This follows the standing `dont-over-engineer-the-migration` principle.

### Production run

Must land with increment 4, so `/news` does not go live empty.

## Testing

Minitest + fixtures + Mocha, mirroring `app/` namespacing.

- **Models** — validations, `domain` enum, slug generation and per-domain scoping, published scope.
- **`BodyRenderer`** — heading shift, raw-HTML escaping, the sanitizer allowlist, and that render is
  a pure function of the stored source.
- **Controllers** — behaviour only: status codes, that a draft 404s, that a topic page returns the
  right posts and only those.
- **Migrator** — against legacy fixtures, including the round-trip text assertion.
- **E2E (Playwright)** — index, a post page, a topic page, per site. CI does **not** run these.

Three guardrails this codebase has earned the hard way:

- Filter and scope tests assert `assert_equal [expected_ids]`, never `assert_empty` — an empty
  result is what a working filter and a deleted filter both produce.
- Every new test is verified by deleting the code under test and watching it go red before it is
  trusted. This applies to component assertions too: Capybara's `text:` is a substring match with
  `default_normalize_ws` false.
- Sort assertions must not coincide with fixture id order — fixture timestamps are per-file, so a
  `created_at` tiebreak resolves on `id`.

New views go through `test/lint/daisyui_v4_classes_test.rb` (empty allowlist, keep it that way).
The admin preview Turbo Frame is checked against `assert_no_frame_trapped_links`; note that guard
is anchors-only, so any form inside a `target: "_top"` frame needs
`data: {turbo_frame: "<frame_id>"}` explicitly.

## Increments

Books first, then games and music.

1. **Data model + renderer** — three tables, `NewsPost`, `NewsTopic`, `NewsPostTopic`,
   `BodyRenderer`, the `commonmarker` gem. Model and service tests. No UI.
2. **Migration** — legacy models, migrator, rake task, round-trip check, dev run, read-through.
   Deliberately early so increments 3 and 4 are built against real content, not fixtures.
3. **Admin (books)** — shared controllers, post form, server-rendered preview, topics CRUD, image
   uploads, sidebar entry.
4. **Public (books)** — index, post page, topic pages, pagination, Open Graph tags, caching, the two
   legacy 301s, E2E specs. Production migration runs with this.
5. **RSS** — feed template and route format.
6. **Games and music** — routes and admin are already domain-scoped, so this is nav entries, the two
   layouts' Open Graph tags, seed topics, and E2E specs.

## Out of scope

- **Automatic posting to Twitter and Facebook.** The Markdown source, `summary` field, share image
  and RSS feed are the groundwork; the posting itself is a separate project. The feed may make it
  unnecessary to write any code at all.
- **The JS bundle work.** Measured on 2026-08-19: `application.js` is **864 KB unminified** and is
  loaded by every layout, public and admin. The per-domain bundles Rollup emits are referenced by
  no layout — `app/views/layouts/application.html.erb:23` asks for `"#{current_domain}/application"`,
  a path Rollup never produces. CSS is minified; JS is not. That is three separate pieces of work
  (enable JS minification, wire the built domain bundles to their layouts, split admin from public),
  none of which depend on news, and all of which change what JavaScript every page on every site
  loads — a blast radius that deserves its own regression pass.
- **A homepage "latest news" strip.** What the dead `front_page` flag was for. Not selected.
- **Pinned posts.** A boolean and a sort clause if it is ever missed.
- **Inline image uploads integrated into an editor.** The body-image uploader hands back a Markdown
  snippet; wiring it into a rich editor waits on the bundle split.

## Working notes

Work happens in the `news-posts` worktree (`.claude/worktrees/news-posts`, branch `news-posts`).
Worktree hazards that apply: `COMPOSE_PROJECT_NAME=the-greatest` for any `docker compose`; diff
`schema.rb` before every commit, since `db:migrate` imports other agents' migrations; confirm what
is actually serving port 3000 before trusting an E2E run; the test database is **not** isolated
between worktrees. `.env` is symlinked from the main checkout.

The development database is not disposable — books data exists only in development and takes hours
to rebuild. Snapshot with `bin/snapshot-dev-db.sh --label pre-news-migration` before the migration
run.
