# Reader profile page (books) — design

Date: 2026-11-19. Status: awaiting owner approval.

## Intent

Give every books user a page about their own reading that is enjoyable to look at: what they
love, what they read lately, how much, what their taste is, how their goals are going, and what
to read next. Let them opt in to a public version they can send to someone, showing only the
sections they choose.

Two pages, one layout:

- **Own profile** at `/my/profile` — everything, only the signed-in owner, never cached.
- **Public profile** at `/profiles/:id` — only opted-in sections, identical for every visitor,
  edge-cached.

## Goals

- A dashboard of the reader's data built entirely from what is already stored.
- A page that keeps its shape and looks deliberate for an account with almost no data.
- Opt-in sharing with one settings screen that fully answers "what can other people see".
- No stale numbers and no new write-path hooks.

## Non-goals

- Music, games, movies. Books host only.
- Handles/usernames, following, comments, a directory or search of profiles.
- Links from public lists, goals or reviews to the owner's profile (those pages are edge-cached;
  linking would need purges on every profile toggle). Later.
- Profile photos. The header uses a daisyUI placeholder avatar with the name's initial. The
  stored `users.photo_url` is a provider photo the user never agreed to publish.
- Charts beyond simple bars, year-in-review, reading streaks, page counts.
- API or MCP exposure.
- Recommendations on the public profile.

## Anti-goals

- A visitor learning anything from a section the owner left off, including that it exists.
- A number that is wrong rather than absent (a "0 this year" for a reader with no finish dates).
- A public page that varies per viewer (it would break edge caching).
- Empty public sections, prompts or upsells shown to visitors.

## What exists today (verified in code and the dev database, 2026-11-19)

- `Books::UserList` default lists `favorites`, `read`, `reading`, `want_to_read`; items carry
  `position`, `completed_on` (read list only), `created_at`. Each list has its own `public` flag.
- `Review` (polymorphic `reviewable`): `rating` (decimal, quarter stars), optional `title`/`body`,
  one per user per book.
- `Books::ReadingGoal` with `target_count`, `starts_on`, `ends_on`, `public`; scope `active_on`;
  progress from `Services::Books::ReadingGoals::ProgressQuery` (takes `catalog_only:`).
- `Recommendations::Engine.call(user:, domain:, limit:, overrides:)` returns `items` and a
  `profile`; `Recommendations::ProfileBuilder` produces the taste profile (`genres`, `subjects`,
  `locations` as `[category_id, weight]` pairs, plus `counts`). Free accounts get recommendations
  (`free_limit`), members more; only editing settings is member-gated.
- Public pages follow one rule (see `Books::ReadingGoalsController`): public = edge-cached via
  `Cacheable`, identical for all viewers, catalog books only; private = `prevent_caching` and 404
  for non-owners. Edge purges go through `Books::ReadingGoals::PurgeCachedPagesJob`.
- `UserAuthenticationService` overwrites `users.display_name` with the provider's name on every
  social sign-in. Only 838 of 71,198 users have one.
- Data shape: 32,236 users have read items; median 20, p90 116, p99 426, max 24,563. Only 94,679
  of 1,583,854 read items (6%) have `completed_on`. 153,734 book ratings from 1,623 users, 18,240
  with text. 424 goals from 392 users.

## Approaches

1. **Compute on request (chosen).** One service gathers a user's profile data with indexed
   queries and reuses the recommendation taste builder. Own page uncached; public page
   edge-cached briefly. New storage is one settings table. Nothing can go stale and no write path
   needs to know the profile exists.
2. **Precomputed snapshot.** A Sidekiq job writes each user's numbers to a table whenever lists,
   ratings or goals change. Fastest pages, but every write path must trigger a refresh, the page
   lags the user's last action, and book ids stored in a new place become the book merger's
   problem. Rejected: too much machinery for an occasionally viewed page.
3. **Each card loads itself (Turbo Frames).** Instant shell, eight requests per view, a public
   page cached in eight pieces. Rejected for now; it can be applied later to a single card if
   measurement shows that card is slow.

The owner picked 1.

## Decisions made with the owner

- Books only. Two pages, private and public. Private page first, sharing second.
- Public URL is numeric, `/profiles/:id`, with a display name required at opt-in.
- The profile has its own per-section switches, all off until switched on. A switched-on section
  shows a preview even if the underlying list or goal is private; it links through to the full
  list or goal only when that list or goal is itself public.
- Recommendations appear on the own profile for every signed-in user and never on the public one.
- Layout is the "dashboard" shape: header, a row of stat tiles, then a two-column grid of cards
  that stacks to one column on a phone.
- Empty-state handling as described under "Empty states" below.

## Page content

Section order in the card grid: Favorites, Goal + Reading now, Taste, Recently read (+ Highest
rated), Recent reviews, Recommendations.

| Section | Definition | Switch |
|---|---|---|
| Header | Display name, "Member since <year of users.created_at>", initial avatar. Own page: privacy status and a "Share settings" button. | always |
| Stat: books read | Count of items on the `read` list. | `show_stats` |
| Stat: read in the last 12 months | Read items with `completed_on` in the trailing 12 months. Shown only when that count is at least 1 (see Empty states). | `show_stats` |
| Stat: average rating | Mean of the user's book ratings, one decimal, with the ratings count. | `show_stats` |
| Stat: reviews | Count of the user's book reviews that have a body. | `show_stats` |
| Favorites | First 8 of the `favorites` list in list order. | `show_favorites` |
| Reading goal | Every goal active today: name, "N of M", progress bar, days left. No on-pace/behind judgement. | `show_goals` |
| Reading now | Up to 4 from the `reading` list. Shares a card with the goal. | `show_reading_now` |
| Favorite genres | Top 5 genres from the taste profile as labelled bars scaled to the strongest. | `show_taste` |
| Favorite subjects | Top 8 subjects from the taste profile as badges. Names link to the category page. | `show_taste` |
| Recently read | 8 read items, `completed_on` descending with undated items after, then newest added. | `show_recently_read` |
| Highest rated | 8 books by rating descending, then most recently rated. Shares a card with Recently read. | `show_top_rated` |
| Recent reviews | Latest 3 reviews with a body: cover, title, stars, truncated body. | `show_reviews` |
| Recommended for you | 6 items from the engine using the user's stored settings; links to `/recommendations`. | own page only |

"See all" links: on the own page they go to the owner's pages (`/my/lists/:id`, `/my/reviews`,
`/my/reading-goals`). On the public page a link appears only when its target is itself public.

Locations from the taste profile are not shown.

## Empty states

Own page:

- An empty primary card (Favorites, Goal, Taste, Recent reviews, Recommendations) stays in place
  as a dashed card with one sentence and one link to the action that fills it.
- Taste needs at least 10 distinct books that are favorited, read or rated; want-to-read and
  reading do not count toward the minimum. Below that the card says how many there are so far.
  The threshold is a constant.
- Secondary blocks (Highest rated, Reading now) are omitted when empty.
- A stat with nothing to count shows a dash, not zero. The "last 12 months" tile shows a number
  only when at least one dated read falls inside the window; otherwise it shows a dash and an
  "Add finish dates" link to the read list. It never shows 0: of the 1,182 users with any dated
  read, 573 have none in the window, and 176 of those added undated reads in that period, so a 0
  would often be wrong. (Author's call.)
- Header name: `users.display_name` when present, otherwise the heading reads "Your profile" and
  the avatar is a generic user icon. Never anything derived from the email address. The preview
  and public templates use only `books_profiles.display_name`. (Author's call.)
- Recommendations: no history → prompt linking to the recommendations wizard; engine unavailable
  or degraded-to-empty → the card is omitted. The page never errors because the engine did.

Public page:

- A section that is off, or on but empty, is absent. No placeholder, no prompt.
- A stat with nothing to count is omitted; the tile row closes up.
- With everything off or empty the page is the header alone and must still look finished.

## Sharing

New table `books_profiles` (model `Books::Profile`, `User has_one`, destroyed with the user):

- `user_id` (unique, FK), `public` boolean default false, `display_name` string,
- one boolean per switch, all default false: `show_stats`, `show_favorites`, `show_goals`,
  `show_reading_now`, `show_taste`, `show_recently_read`, `show_top_rated`, `show_reviews`.

It holds no book ids, so the book merger is unaffected.

The profile keeps its own `display_name` because sign-in overwrites the account one. It is
prefilled from `users.display_name`, required when `public` is true, stripped, 2–40 characters,
not unique. The auth service is not changed.

Routes, books host only:

- `GET /my/profile` — own page. Signed-out users get the usual sign-in handling for `/my/*`.
- `GET /my/profile/settings`, `PATCH /my/profile/settings` — the sharing form: public on/off,
  display name, the eight switches, the public URL to copy once public. The row is created on
  first save, never on GET.
- `GET /my/profile/preview` — the public template rendered for the owner, uncached, whether or
  not the profile is public, so they can check it before publishing.
- `GET /profiles/:id` — `:id` is the `books_profiles` id, not the user id. Not public → 404 for
  everyone, owner included, with `prevent_caching`.

Public page rules:

- Catalog books only (`Books::Book.catalog`), in lists, counts and ratings alike.
- `noindex`, and not in sitemaps.
- Cached for 10 minutes at the edge only (`s-maxage`, with no browser lifetime), because a purge
  cannot reach a browser's own cache.
- A save that reduces what is visible (profile made private, a section switched off, the display
  name changed) follows `Services::Books::ReadingGoals::SaveGoal`: purge synchronously through
  `Cloudflare::PurgeService` on every books host, fall back to the purge job if that fails, and
  tell the owner when the purge could not be confirmed. Queueing a job alone is not enough.
  (Author's call, from the project's precedent.)
- Account deletion purges the same way.
- Ordinary data changes (a new read book, a new rating) are not purged; they appear when the
  cache expires.
- No admin moderation of profiles or display names. The owner is not worried about abusive names
  and decided against building protection for them.

## How it is built

- `Services::Books::Profiles::Build` (Result pattern) takes a user and an audience (`:owner` or
  `:public`) and returns one plain data object the views render. The audience decides catalog-only
  filtering and which sections are computed. For `:public`, a switched-off section is never
  queried, so it cannot leak through a view mistake.
- Taste comes from `Recommendations::ProfileBuilder` through the books recommendation adapter, the
  same inputs the recommendations page uses, so the two pages agree. The public page uses the
  identical calculation, decided by the owner: it draws on favorites, read, reading, want-to-read
  and every rating regardless of list privacy, the other switches or the catalog flag, and shows
  only genre and subject names. The settings form says so next to the taste switch.
- ViewComponents per card, shared by both pages; daisyUI 5 (`stats`, `card`, `progress`, `badge`,
  `avatar avatar-placeholder`) on Tailwind 4, checked against
  `docs/external-libraries/daisyui-llms.txt`. No meaning carried by colour alone.
- Controllers: `Books::My::ProfilesController` (own page, settings, preview) and
  `Books::ProfilesController` (public), following `Books::My::ReadingGoalsController` and
  `Books::ReadingGoalsController`.
- A "Profile" entry in the books account navigation.
- Book rows preload what covers and titles need (`Books::UserList.listable_display_includes`);
  the page must not issue per-book queries.

## Phases

1. **Own profile.** `/my/profile`, the build service for `:owner`, all cards and empty states,
   nav link. No new table.
2. **Sharing.** `books_profiles`, settings, preview, public page, caching and purge.

Each phase ships on its own.

## Testing

- Unit tests for the build service: every section's definition, the 10-book taste threshold, the
  dated-reads rule, catalog-only for `:public`, and that `:public` does not compute switched-off
  sections.
- Controller tests for behaviour: auth on `/my/*`, 404 for a non-public profile (owner included),
  cache headers on public vs private, settings validation, the confirmed purge on a save that
  hides something (and its unconfirmed fallback), row not created on GET.
- A privacy test: a public profile with one section off does not contain that section's data.
- Playwright: own profile for a seeded account and for an empty one; publish from settings and
  open the public URL signed out.

## Left to the builder

- Whether the own page takes taste and recommendations from one `Engine` call or two.
- Whether the taste result needs caching: measure on the 24,563-read account first; if it does,
  cache per user with a short expiry.
- Exact copy for prompts, card internals, cover sizes, how many items fit at each breakpoint.
- Component boundaries and names beyond those given.
- Where the purge URL list lives (a `CachedUrls` service like the goals one is the precedent).
