# Todo

## Auth

**fix the legacy app's client-supplied email fallback** — *time-boxed*
`the-greatest-books/admin/app/controllers/users_controller.rb:144` reads
`decoded_user_data[:email] || provider_data[:email]`, and the second half is the browser's
own form post, bound to nothing. A genuine token plus an edited `providerData[0].email`
relinks any account to the attacker's uid. Publishing the new Meta app made this easy to
reach, because every Facebook token now lacks the `email` claim the fallback keys on.
The same file also picks its JWT algorithm from the token's *unverified* header, and acts
on validation errors only when the visitor is already signed in.
Retires with the legacy site, so this is only worth doing if that slips. No CI there —
merging is deploying.

## Legacy account recovery

Both routes below serve the Facebook cohort orphaned when the old Meta app died: 17,531
rows, not one with an email on the row, none signed in since **2020-09-23**. Full detail
is in `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md` (F8, F9, D11,
D11a) — these entries are pointers, not the design.

**backfill emails from `legacy_v1_data`** — larger, simpler, no Meta involvement
12,683 addresses are recoverable from the stored V1 blob. 398 collide with an existing row
and need a merge rather than an update. Until this runs, a returning Facebook or X user
from the old cohort still lands on a new row even though the sign-in path now resolves
their address correctly — `find_user` matches against `users.email`, and theirs is NULL.

**recover the email-less cohort via Meta's Business Mapping API** — smaller, harder
**Confirmed working 2026-09-07.** Both apps are claimed by the same Business Manager, and
`GET /me?fields=ids_for_business` returns both ids — `10166754100896840` (The Greatest)
and `10160972764671840` (The Greatest (Old)), the latter being exactly what `users#42207`
holds. 4,848 rows have no address anywhere; **3,139 of them hold real saved content**
(83,231 list items between them — the remainder is empty default scaffolding).

Design constraints for whoever writes this:

- The Facebook user access token comes from `FacebookAuthProvider.credentialFromResult()`
  on the client, so it is attacker-controlled. Verify it against Facebook's `/debug_token`
  and **require the `user_id` it resolves to equal the ASID inside the Google-signed
  Firebase ID token**. That binding is what stops someone claiming a stranger's account.
- **A uid match must never outrank an email match.** Shane's own rows prove why: the
  Facebook uid matches `42207`, an empty V1 stub, while the email matches `1141`, the real
  account. Uid is a fallback, used only when the email finds nothing.
- **Do not delete the old Meta app.** It is the only thing keeping this possible.

## Goodreads import: before the cutover

The manual launch steps live in `docs/launch-todo.md`. These are code fixes, deferred from the
increment 6 and 7 PRs (#355, #359), that a member or an admin would hit after launch.

- **Viewer staff can read the admin import pages.** They follow the other books admin pages, but
  spec §10 says admin-only. They show every member's shelves, dates and reviews.
- **A failed upload save leaves the member stuck.** If saving the file to R2 fails at commit, the
  import sits queued with no job. The one-import-at-a-time rule then blocks the member's next upload
  until an admin acts on it (2 h later, when it shows as stuck).
- **A shelf named only `-` fails the whole import.**
- **The admin Created and Flagged tabs aren't paginated.** The two biggest legacy imports that
  `finish_legacy` runs have 10,000 and 11,418 rows.
- **A row decided while Open Library was failing is never re-matched** unless an admin re-checks
  it. An Open Library outage during launch would leave flagged rows, and books created from
  them, with no automatic retry. A task that re-checks decisions with `open_library` in
  `sources_failed` would cover it.
- **Smaller ones:**
  - after Reject, the member's summary still shows rows as Matched; only the banner explains;
  - a skipped row can still fill a blank read date, or take the book off the reading list;
  - a summary recalculation that errors after the write isn't retried;
  - an upload parameter that isn't a file returns 500 instead of 422.
- **Test gaps:** no test that an editor is refused on untick, reject or delete, and no end-to-end
  test of settle → resume → complete.
- **Find what called `/resolve` from 16:55 to 17:17 UTC on 2026-10-06.** No Goodreads import or
  test was running. Production Rails logs for that window would show the caller.
- **After launch, watch the flag rate when many members upload at once.** Every caller shares one
  Open Library `/resolve` slot (#358), at about 13 s each. A lookup that can't get the slot within
  its 60 s budget is decided without Open Library.

## Data importers
- google books integration
- **port the legacy add-book modal** (Goodreads URL, Amazon URL, or title and author). A non-goal of
  the Goodreads import spec, left as its own project.
- **finder initials gap:** "J.D. Salinger" fails to match "J. D. Salinger" (found by the Goodreads
  replay).

## Books data quality
- Books Duplicate fixer
- Authors Duplicate fixer
- Invalid Book Finder
- old archived ranking configurations

## Product

- recommendations
- add list wizard

## Growth and infra

- google ads
- google analytics
- move worker to a new server

- Series populator: `Books::Series` is empty. Cached Goodreads pages keep each book's Goodreads
  series ids (`series` on the page rows), so they can seed it.
- series UI

- new books added are not automatically enriched
- category importer
- category cleanup
- import from storygraph
- series import (use goodreads data)
