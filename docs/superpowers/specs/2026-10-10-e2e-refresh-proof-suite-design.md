# E2E suite: refresh-proof accounts and a green baseline

**Date:** 2026-10-10
**Status:** approved design, awaiting implementation plan

## Problem

`yarn test:e2e` is the most important test suite in the system, and it breaks after
every `bin/refresh-dev-db.sh`. The refresh restores the production dump wholesale, and
everything the suite relies on that is not production data goes with it: the Playwright
accounts' `User` rows, their roles, their seeded reviews and lists, and the sandbox Stripe
price ids. Four manual rake tasks and an edit to `e2e/.env` bring some of it back, and
nobody remembers all of them.

A baseline run on 2026-10-10, after applying every documented manual step, gave:

| Outcome     | Tests |
|-------------|-------|
| Passed      | 483   |
| Failed      | 12    |
| Did not run | 10    |

Before the manual steps nothing could run: the admin `User` row did not exist. The failures
have eight causes, and this design removes every one of them.

| # | Cause | Tests | Kind |
|---|-------|-------|------|
| 1 | Playwright 1.64 installed, its Chromium never downloaded | all | per-upgrade |
| 2 | Admin role, 30 seeded reviews, two seeded lists and their `.env` ids live in the replaced database | all admin + account projects | per-refresh |
| 3 | Member account never configured: no Firebase user, no env entry | 1 setup + 10 did not run | one-time |
| 4 | `billing_plans` carries live Stripe price ids from the dump; dev uses a sandbox | 2 | per-refresh |
| 5 | Admin "New Category" renders all 83,425 books categories as `<select>` options | 4 | app defect on prod data |
| 6 | Locator rot from merged features (nav links, second Search button, second "Public" label) | 4 | spec rot |
| 7 | Logout spec clicks the hint-rendered "Logout" before Firebase has wired the click | 1 | race |
| 8 | Contact spec exhausts the per-IP rate limit on a second run within an hour | 0 this run, known | per-rerun |

## Goals

- A refresh from production needs **zero** manual E2E steps afterwards.
- Three roles are exercised by three distinct accounts: admin, normal user, paid member.
- The suite depends on no user data that exists only in one database. It may assume that
  very famous, highly ranked books keep their slugs and ids across refreshes.
- Two consecutive full runs on the same database are both fully green.

## Non-goals (stated so nobody adds them back)

- **CI.** The suite needs a production-shaped catalog, OpenSearch, Redis, TLS on three
  hostnames, Firebase and a Stripe sandbox. That is a staging-stack project, decided out of
  scope on 2026-10-10. This design keeps the door open (non-interactive prepare, env-only
  configuration, browser install in the script) and nothing more.
- Renaming the music project from `chromium`.
- Any change to how the navbar hint script renders the Login/Logout label (the cancelled
  navbar-flash work).
- Trimming the development dataset.
- Creating Firebase accounts from the suite. The email-auth spec already refuses to sign up
  because every signup creates a real account in the shared production Firebase project.

## Design

### 1. Accounts

Three Firebase email/password accounts, created once by hand in the Firebase console.
`e2e/.env` holds only credentials:

```env
PLAYWRIGHT_ADMIN_EMAIL=...
PLAYWRIGHT_ADMIN_PASSWORD="..."
PLAYWRIGHT_USER_EMAIL=...
PLAYWRIGHT_USER_PASSWORD="..."
PLAYWRIGHT_MEMBER_EMAIL=...
PLAYWRIGHT_MEMBER_PASSWORD="..."
```

`PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID` and `PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID` are removed from
`.env` and `.env.example`.

| Account | Role | Membership | Drives |
|---------|------|------------|--------|
| admin   | global `admin` | none, enforced | music, games, `books-admin` |
| user    | `user` | none, enforced | `books-account` |
| member  | `user` | comped, active | `books-member` |

No account is ever admin and member at once, so the paywall specs stay meaningful. The
`e2e:prepare` task (section 3) enforces every cell of this table on every run.

### 2. Playwright side

**Shared sign-in helper, `e2e/support/sign-in.ts`.** Drives the login modal (email,
Continue, password, Sign In) and then waits for the real signal: it polls
`context.cookies()` until both `tg_uid` and `_the_greatest_session` are present, then saves
the storage state. This retires `waitForTimeout(3000)` in the books and games setups and the
"Logout" label wait in the music setup, which is the capture race recorded in memory as a
live flake.

**Five setup projects**, each a few lines around the helper:

| Project | Account | Base URL | Storage state |
|---------|---------|----------|---------------|
| `setup` | admin | dev.thegreatestmusic.org | `.auth/user.json` |
| `games-setup` | admin | dev.thegreatest.games | `.auth/games-user.json` |
| `books-setup` | admin | dev-new.thegreatestbooks.org | `.auth/books-user.json` |
| `books-user-setup` | user | dev-new.thegreatestbooks.org | `.auth/books-normal-user.json` |
| `books-member-setup` | member | dev-new.thegreatestbooks.org | `.auth/books-member.json` |

**The `seed` project.** Depends on all five setups. Its single test runs
`bin/rails e2e:prepare` from `web-app` with `execSync`, the pattern eleven specs already use,
and fails with the task's own output if it exits non-zero. Every test project lists `seed`
in `dependencies`, so no test runs against unprepared state. On a fresh refresh the order
is: five browser sign-ins create the `User` rows (sign-in is the only way rows come to exist,
unchanged), prepare promotes and seeds them, tests run.

**The manifest, `e2e/.auth/seed.json`** (gitignored with the storage states). Written by
prepare; read by `e2e/support/seed.ts`, which throws "run the seed project first" if the
file is missing, so a single-spec run without the seed step fails in one clear line rather
than on an undefined id. Contents: the three user ids and emails, the public and private
list ids, the verified slugs, and a timestamp.

**Project mapping.** `books-account` switches to the user's storage state. `books-admin`
keeps the admin. `books-member` keeps the member. Music and games stay on the admin; they
have no account-level specs.

**Browser install.** The four `test:e2e*` scripts in `package.json` run
`npx playwright install chromium &&` before the test command. A no-op when the browser is
present, a download after a Playwright bump; a version upgrade can no longer kill the suite
before the first page.

### 3. `bin/rails e2e:prepare`

One rake task in `lib/tasks/e2e.rake` backed by `Services::E2e::Prepare` in
`app/lib/services/e2e/prepare.rb`, so it has a Minitest test like any other service. It
runs top to bottom, each step idempotent, one printed line per step. It never deletes
anything it did not create, with the one exception in step 3.

1. **Resolve the three accounts.** Read the three emails from `e2e/.env` the way the existing
   tasks do. Find each `User` by email. If any is missing, abort: "no User for \<email\>; the
   seed project signs it in first." A failed browser sign-in is reported as that.
2. **Roles and membership.** Admin: `role: :admin`. User and admin: `role` as stated, and
   every membership they hold that `granting_access` would count (the scope behind
   `User#member?`) is set to `status: :canceled`, so a comp applied by hand cannot make the
   paywall specs vacuous. Member: `role: :user` plus a comped membership,
   exactly as `e2e:member` does today (`find_or_initialize_by(source: :comped)`, active, no
   end date, the existing `note`). Nothing new on `User`.
3. **Owned seed data, reset to exact state.** The three accounts exist only for this suite;
   their own rows are disposable. The user account gets exactly 30 `Books::Book` reviews,
   six per rating, including the "Animal Farm" anchor the search test needs, built as
   `e2e:my_reviews` does but **after removing that account's existing book reviews**, so an
   interrupted run or a stray review can no longer break the exact-count assertion. The same
   account gets the "E2E Public Books" (public, three items) and "E2E Private Books"
   (private, one item) lists. Every deletion is scoped to `user.reviews` or
   `user.user_lists` of these three accounts, never to a table, and the service test proves
   that scope by asserting another user's rows are untouched. The `block-destructive-db`
   hook matches `rails runner` and raw SQL; a task that names its owner is the intended
   path.
4. **Stripe.** Call `Services::Billing::SyncPlans` and fail if it fails. The forgotten
   post-refresh step becomes part of every run.
5. **Rate limiter.** Clear `Rails.application.config.x.rate_limit_store`, the namespaced
   store whose `.clear` is a scoped delete (see the initializer comment).
6. **Catalog preflight.** Verify the slugs the specs assume: books `war-and-peace`,
   `headlong-hall`, `animal-farm`, `the-great-gatsby`, `room-for-murder`; the books genre
   `novels`; the games category `action`. List every missing one and abort. A refresh that
   renames a famous slug fails in one line instead of in a dozen specs.
7. **Manifest.** Write `e2e/.auth/seed.json`.

A companion `e2e:rate_limit_reset` task performs step 5 alone, for the contact spec's own
`beforeAll` so a single-spec rerun owns its reset.

**Removed:** `e2e:admin`, `e2e:member`, `e2e:my_reviews`, `e2e:books_public_list`. The
feature doc points at prepare. The per-spec seed and cleanup tasks (import finder, reject
link, provisional, Goodreads, repair verdicts, list wizard) are unchanged; those specs keep
owning their own setup and teardown.

### 4. Spec changes

**Moved to the user account** (via the `books-account` project switch): everything under
`tests/books/account/`, with three adjustments.

- The Goodreads import seed and cleanup in `account/goodreads-import.spec.ts` run under the
  user's email: the spec passes `E2E_GOODREADS_EMAIL` from the manifest, which the tasks
  already accept. The admin approval spec in `admin/goodreads-imports.spec.ts` keeps the
  admin email.
- `account/my-lists.spec.ts` and the public-project `books/public-list.spec.ts` read the list
  ids from the seed helper. The lists belong to the user account; the public spec only views
  them, which is why the `books` project also depends on `seed`.
- `membership.spec.ts` keeps "a signed-in non-member is turned away"; its header comment
  changes from "do not comp the e2e user" to "prepare strips any membership from this
  account on every run."

`my-reviews.spec.ts` keeps `SEEDED_COUNT = 30` because prepare now guarantees it.

**Locator repairs** (four tests, no app change): the My Books nav expectation adds "Import
from Goodreads" and "My Rankings" in rendered order; the account reviews search scopes its
Search button to the reviews form; the reading-goal "Public" check scopes to the goal form.

**Race repairs** use the new signal from section 5: `music/auth/logout.spec.ts` and
`login.spec.ts` wait for `data-auth-state` on the navbar button, not its label.

**Contact rate limit:** `books/contact.spec.ts` gains a `beforeAll` calling
`bin/rails e2e:rate_limit_reset`.

### 5. App fixes

**Category parent chooser.** `Admin::Categories::FormComponent` renders
`parent_categories` as a `<select>`; on production data that is 83k options for books and
the create flow times out. The parent field becomes the existing `AutocompleteComponent`
against the domain's admin categories search path (the same `search_url` resolution
`Admin::AddCategoryModalComponent` uses, via `Admin::DomainNav`'s `categories_search_path`
with `search_admin_categories_path` as the fallback), writing a hidden `parent_id`. Same
component for every domain. A component test covers rendering with and without a parent;
the four category E2E tests cover the flow and gain one that chooses a parent through the
typeahead. The edit form must preselect the current parent (name shown, id in the hidden
field).

**Auth-wired signal.** `updateNavbarButton` in `authentication_controller.js` sets
`data-auth-state="signed-in"` or `"signed-out"` on `#navbar_login_button` at the moment it
wires the click handler. The hint script does not touch the attribute, so before Firebase
resolves it is absent. Three lines; the hint rendering is untouched.

### 6. Verification, in order, before the branch is done

1. `bin/rails test` and `bundle exec standardrb` green, including the new service test and
   component test.
2. Two consecutive full `yarn test:e2e` runs on the same database with no manual step between
   them, both fully green, zero "did not run." The second run proves idempotency and the
   rate-limit reset.
3. Refresh rehearsal without a restore: `bin/snapshot-dev-db.sh --label pre-e2e-rehearsal`,
   delete the three e2e `User` rows and everything they own with a one-off runner scoped to
   those ids, run `yarn test:e2e`, confirm green, `--restore`.
4. Negative checks: comp the user account by hand and confirm the paywall tests fail; remove
   the `data-auth-state` write and confirm the logout spec fails. Both prove the new signals
   are not vacuous.

Port 3000 must belong to this checkout for every run (`AGENTS.md` has the check).

### 7. Documentation and memory

- `docs/features/e2e-testing.md` rewritten around the three accounts, the seed project, the
  manifest and the one-time Firebase setup. The "re-run `e2e:admin` after a refresh" guidance
  is deleted.
- `AGENTS.md`, refresh section: one sentence, "a refresh needs no E2E steps; `e2e:prepare`
  runs inside every `yarn test:e2e`."
- After merge, the memory notes on `e2e:admin` and the hourly contact rate limit are updated.

## Open questions

None. The one implementation-time check (which endpoint the add-category typeahead uses) is
resolved above.
