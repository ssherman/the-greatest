# Reader Profile (books)

A signed-in reader's own profile page at `/my/profile` on the books site, linked first in the
"My Books" menu, plus an opt-in public page. It summarises what the reader has done on the site: reading, rating, reviewing,
goals and taste. Design: `docs/superpowers/specs/2026-11-19-reader-profile-design.md`.

A reader can also share a read-only copy at `/profiles/:id` (id of the profile row, not the user),
choosing which sections visitors see. Sharing is off until the reader turns it on.

## What each section means

- **Header.** Display name and "Member since <year>". No name means a generic "Your profile"
  heading and a generic icon; nothing is ever derived from the email address.
- **Stat row.** Books read, books read in the last 12 months, average rating (with the number of
  ratings), and review count. A tile with nothing to count shows a dash. "Read in the last 12
  months" counts only books with a finish date, so a dash there links to the Read list with "Add
  finish dates".
- **Favorites.** The cover shelf from the reader's Favorites list, with a "See all (N)" link to the
  list page.
- **Reading goal.** Every active goal with progress and days left, plus the books being read now.
- **Taste.** Favorite genres as bars scaled to the strongest, and favorite subjects as badges,
  both derived from the reader's default lists (Favorites, Read, Reading, Want to Read, not
  custom lists) plus reviewed books. Taste needs at least 10 favorited, read or rated books.
- **Recently read.** Cover shelf from the Read list.
- **Highest rated.** Its own cover shelf of the reader's best-rated books, each with its rating.
- **Recent reviews.** The latest reviews with cover, stars and a snippet; "See all" goes to
  `/my/reviews`.
- **Recommended for you.** Eight covers from the recommendation engine, with "See all".

Layout: the cover shelves (Favorites, Recently read, Highest rated, Recommended for you) run the
full width, eight covers to a row on desktop and four on a phone. The small cards between them
(Reading goal, Taste, Recent reviews) flow in two columns, each sitting directly under the one
above it, so a missing or short card leaves no hole. On the page the order is Favorites, Recently
read, the small cards, Highest rated, then Recommended for you.

## Empty-state rules

- **Primary cards** (Favorites, Reading goal, Reviews, Taste, Recommendations) show a prompt to
  the owner when empty, with a button to the place that fills them: find books, set a goal, and
  so on.
- **Taste** needs a minimum number of qualifying books (`Services::Books::Profiles::Taste::MIN_BOOKS`);
  below it the owner sees "N of M" progress instead.
- **Recently read** and **Highest rated** are secondary: when empty each renders nothing and
  leaves no gap.
- **Recommendations** show only to the owner. If the engine fails or returns nothing, the card is
  omitted rather than showing an error. A reader with no history gets a prompt for the
  recommendation wizard.
- The stat row always renders for the owner.

## Sharing model

- A profile row (`Books::Profile`) exists only once the reader saves Share settings; before that
  the profile is private. `/my/profile/settings` shows and saves the form, `/my/profile/preview`
  shows the owner exactly what a visitor would see (public audience, even while private, once a profile row exists; with no row it redirects to settings).
- The row holds `public`, a `display_name` (2 to 40 characters, required while public; nothing is
  ever derived from the email address) and eight switches, all off by default: stats, favorites,
  goals, reading now, taste, recently read, highest rated, reviews.
- The page header on `/my/profile` shows the sharing status and a "Share settings" link; the
  public page shows only the name and "Member since".
- The settings page shows the public link whenever the stored profile is public; read it from
  there.

## What each audience sees

- **Owner** (`/my/profile`): every section, with prompts for empty ones, the Recommended card,
  and books outside the public catalog. Never cached.
- **Public** (`/profiles/:id`): identical for every viewer, the owner and admins included. Only
  switched-on sections, only books in the public catalog, and a section that is on but empty
  leaves no gap, so a profile with every switch off is the header alone. A shelf or goal links
  to its list page only when that list is itself public. No recommendations and no prompts.
  Taste appears only once it is ready.
- A switched-off section is never computed for the public page, so it never touches the
  database or the taste cache.
- A private or missing profile is a 404 for everyone, so the URL says nothing about whether the
  account exists.

## Taste

Genres and subjects come from the recommendation engine's taste profile built from the reader's
default lists (Favorites, Read, Reading, Want to Read; not custom lists) and reviewed books, the
same input the recommendations use. The 10-book minimum counts only favorited, read or rated
books. The public page shows only genre and subject names and each genre's relative strength,
never the books behind them. The result
is cached an hour per user, and only when ready.

## Caching and purge

- The public page is cached at the edge only (Cloudflare, 600 seconds); the header is
  `public, max-age=0, s-maxage=600`, so browsers may store it but must revalidate every time. In development there is no edge, so changes show at once.
  Only the canonical path `/profiles/<id>` is ever cached. A zero-padded id, a trailing slash or a
  query string reaches the same profile but would be a separate edge cache entry the purge cannot
  clear, so each gets an uncached 301 to the canonical path; a `.html` suffix is not routable.
- A save that hides anything the edge may hold (switching public off, turning a section off, or
  changing the display name) purges the cached URL synchronously after the commit, and the
  settings page says something only when the purge was not confirmed (a confirmed one shows the
  plain "Profile settings saved."). Then the save still stands, the reader is told the old copy
  clears within 10 minutes, and a retrying job purges it. A save
  that only reveals more enqueues a purge in the background.
- Hiding saves refuse to run inside an enclosing database transaction, because the purge result
  could not be reported.
- Deleting an account deletes the profile, and enqueues the purge job when the profile was public.

## Search engines and moderation

The public page is `noindex` (the layout does not mark it indexable) and the settings page says
search engines are asked not to list it. There is no moderation: the display name and the
reader's own reviews are shown as written, and the reader controls visibility. Report handling,
if ever needed, would be a new feature.

## Behaviour notes

- The owner pages are never cached (`prevent_caching`); the taste result is cached for an hour
  per user, and only when ready, because computing it for the heaviest readers is too slow to do
  per request.
- The owner view is not limited to the public catalog.

## Where the code lives

- Controllers: `web-app/app/controllers/books/my/profiles_controller.rb` (routes `books_my_profile`,
  `books_my_profile_settings`, `books_my_profile_preview`) and
  `web-app/app/controllers/books/profiles_controller.rb` (public `books_profile`).
- Model: `Books::Profile` (switches in `SECTIONS`).
- Services: `web-app/app/lib/services/books/profiles/` (`Build` assembles everything for either audience;
  `Library`, `Taste` and `Recommended` supply the parts; `SaveSettings` saves and purges;
  `CachedUrls` lists the URLs to purge).
- Components: `web-app/app/components/books/profiles/`, one per card.
- Views: `web-app/app/views/books/my/profiles/show.html.erb` and the shared body
  `web-app/app/views/books/profiles/` (`_dashboard`, `_cover`, public `show`); settings and
  preview under `web-app/app/views/books/my/profiles/`.
- Tests: mirrored under `web-app/test/`; E2E in `web-app/e2e/tests/books/account/profile.spec.ts`.
  The sharing flow (settings, public page in a signed-out context, 404 after going private) is in
  the same spec; `e2e:prepare` resets the E2E account's profile to private. The three E2E accounts
  are not empty, so the empty-account render is covered by the controller test, not Playwright.
