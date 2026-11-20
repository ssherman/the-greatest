# Reader Profile (books)

A signed-in reader's own profile page at `/my/profile` on the books site, linked first in the
"My Books" menu. It summarises what the reader has done on the site: reading, rating, reviewing,
goals and taste. Design: `docs/superpowers/specs/2026-11-19-reader-profile-design.md`.

**Status:** phase 1 (the owner's own page) is built. Sharing and a public profile page are
planned (phase 2) and do not exist yet: `Services::Books::Profiles::Build` accepts only the
`:owner` audience and raises for anything else.

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
  both derived from the reader's read and rated books.
- **Recently read.** Cover shelf from the Read list, with a "Highest rated" row in the same card.
- **Recent reviews.** The latest reviews with cover, stars and a snippet; "See all" goes to
  `/my/reviews`.
- **Recommended for you.** Covers from the recommendation engine, with "See all".

## Empty-state rules

- **Primary cards** (Favorites, Reading goal, Reviews, Taste, Recommendations) show a prompt to
  the owner when empty, with a button to the place that fills them: find books, set a goal, and
  so on.
- **Taste** needs a minimum number of qualifying books (`Services::Books::Profiles::Taste::MIN_BOOKS`);
  below it the owner sees "N of M" progress instead.
- **Recently read** is secondary: when empty it renders nothing and leaves no gap.
- **Recommendations** show only to the owner. If the engine fails or returns nothing, the card is
  omitted rather than showing an error. A reader with no history gets a prompt for the
  recommendation wizard.
- The stat row always renders for the owner; a visitor view (phase 2) shows only tiles that have a
  number.

## Behaviour notes

- The page is never cached (`prevent_caching`); the taste result is cached for an hour per user,
  and only when ready, because computing it for the heaviest readers is too slow to do per request.
- The owner view is not limited to the public catalog; the visitor view will be.

## Where the code lives

- Controller: `web-app/app/controllers/books/my/profiles_controller.rb`; route `books_my_profile`.
- Services: `web-app/app/lib/services/books/profiles/` (`Build` assembles everything; `Library`,
  `Taste` and `Recommended` supply the parts).
- Components: `web-app/app/components/books/profiles/`, one per card.
- Views: `web-app/app/views/books/my/profiles/show.html.erb` and the shared body
  `web-app/app/views/books/profiles/` (`_dashboard`, `_cover`), which phase 2 will reuse.
- Tests: mirrored under `web-app/test/`; E2E in `web-app/e2e/tests/books/account/profile.spec.ts`.
  The three E2E accounts are not empty, so the empty-account render is covered by the controller
  test, not Playwright.
