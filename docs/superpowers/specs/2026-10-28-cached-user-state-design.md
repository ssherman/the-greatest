# Cached per-user state: at most one Rails request per page view

Date: 2026-10-28
Status: approved 2026-10-28 (incl. the same-device version cookie, §4)
Follows: `2026-10-26-single-source-sign-in-state-design.md` (PR #422, merged)

## Why

The sites serve millions of page views a day from Cloudflare's edge cache. Pages are byte-identical
for every visitor and per-user bits are filled in by JavaScript from uncached Rails endpoints. For a
signed-in visitor that currently costs, **on every page view**:

| Request | What it returns | What uses it |
|---|---|---|
| `/user_list_state` | every list the user has on this domain, every (list, item) membership, a fresh CSRF token; also renews the sign-in at most daily (PR #422) | the add-to-list widgets and the list modal, which most pages do not have |
| `/membership_state` | `member`, plan, source, `current_period_end`, a CSRF token | only showing/hiding the navbar "Members" link |
| `/review_state` (book show pages only) | this user's rating/review of this book | the review widget |

So a signed-in book page is three Rails requests and every other page is two. The data almost never
changes between page views: it changes when the visitor does something.

Shane's requirements, in his words: "we need to avoid hitting the actual rails server as much as
possible"; "user_list_state should be in localstorage and only be updated when the user does
something"; re-check "once in a while just in case a user moves to mobile"; "only be making a max of
1 server side call per request. definitely not 3". Re-check interval: **once an hour** (Shane).
Book show pages may keep looking up their review state (Shane).

Prior art this follows: client-side caches with write-through on mutation plus time-based
revalidation (stale-while-revalidate with a stale time, as in React Query / Apollo persisted
caches), with conditional requests (ETag → `304 Not Modified`) so a revalidation that finds nothing
changed is nearly free.

## Goals

- A signed-in page view makes **zero** Rails requests in the common case and **never more than
  one**. Anonymous visitors stay at zero.
- Edge-cached HTML stays identical for every visitor (no per-user cookies or markup on cacheable
  responses — the invariant from PR #422 stands).
- The visitor's lists, list memberships and membership status are held in the browser and updated
  from the responses of the visitor's own actions.
- A change made elsewhere (another device, or a server-side change such as a membership expiring)
  shows up within an hour.
- The sign-in keeps renewing (PR #422 renews at most daily from an uncached request).

## Non-goals

- Reading goals. `/my/reading-goals` is a normal page, and the reading-goal state request runs only
  on a public goal's own page. Untouched.
- The contact form's `/contact_state` (contact page only). Untouched.
- Book show pages' `/review_state` lookup stays (Shane). It is that page's one request.
- Cloudflare rate-limit rules (separate, later).
- Real-time cross-device sync (push, websockets) or edge-side personalisation (Workers/ESI).

## Anti-goals

- More than one Rails request on any page view, including the hour the re-check falls due on a
  book page.
- Any Set-Cookie or per-user byte on an edge-cacheable response.
- A visitor seeing another person's lists or membership on a shared browser after sign-out or a
  different sign-in.
- CSRF tokens persisted to localStorage (they stay in memory only, as today).

## Design (decided)

### 1. One combined state endpoint

Replace the per-page `/user_list_state` + `/membership_state` pair with **one** uncached endpoint
returning everything the cached pages need for this user on this domain: lists, memberships, and
membership status (`member`, `current_period_end`, whatever the Members link and existing callers
need). It requires sign-in, returns 401 otherwise (which clears `tg_uid`, as today), and renews the
session (`renew_current_session`) exactly as `/user_list_state` does now.

It supports conditional requests: the response carries an `ETag` (and/or the payload's `version`);
a request presenting the current one gets `304 Not Modified` with no body. **The version must change
on every change to anything in the payload, including deletions** (removing an item, deleting a
list, membership granted/expired). Note that today's `version: current_user.updated_at` does not
satisfy this: list changes touch `user_lists`, not `users`.

The CSV download (`csv_export_controller.js`) also reads membership today, by fetching
`/membership_state` when Download CSV is clicked (its 401 opens the sign-in modal). It keeps a
click-time check against the combined endpoint (conditional, so usually a 304), because it gates a
paid feature and a member who has just paid must not see the non-member dialog. That is a click,
not a page load, so it is outside the budget.

Whether the old endpoint names survive (e.g. `/user_list_state` becomes the combined one and
`/membership_state` is retired) is the builder's call; nothing outside this app calls them.

### 2. The browser cache

- One localStorage entry per domain (extending today's `tg:user_list_state:<domain>`), keyed to the
  user id from `tg_uid`. An entry whose user id does not match `tg_uid` is discarded (shared browser).
- Holds lists, memberships, membership status, the version, and **when it was last checked**.
- Never holds the CSRF token.
- Every page renders per-user UI from it immediately (list widgets, list modal, Members link). The
  My Books / My Lists links keep following `tg_uid` alone (PR #422).

### 3. When the browser talks to Rails

- **Re-check:** on page load, if the entry is missing or was last checked more than **one hour**
  ago, make one conditional request to the combined endpoint. 304 → just update "last checked".
  200 → replace the entry. 401 → clear entry and `tg_uid` (existing behaviour).
- **Otherwise:** no request.
- **Budget rule:** the budget counts requests a page makes **by loading**, not requests the visitor
  causes by clicking (writes, opening the list modal, Download CSV). If the page already costs a
  Rails request by loading, the re-check is **skipped** on that page view and happens on the next
  page that costs none. That covers: pages that make their own state request on load (book show's
  `/review_state`, the contact page's `/contact_state`, a public goal page's reading-goal state),
  and uncached Rails pages (`/my/*`, admin, membership pages), whose HTML is itself the request.
  This is a general per-page signal (e.g. a marker the page's markup carries, identical for every
  visitor), not a books special case. A page view never makes two.
- **Missing entry on a page that cannot re-check** (e.g. signing in from a book page reloads it with
  the entry discarded): the list widgets render empty and fetch the state when the visitor first
  interacts with them (opens the modal / clicks add). The next ordinary page fills the entry.
- **Writes** (add/remove from a list, create a list, completion toggles, anything the widgets do):
  the mutation response already describes the change; the browser applies it to the entry and bumps
  its version. No follow-up fetch.
- **CSRF token:** obtained only when a write is about to happen and none is held in memory for this
  page (e.g. a token-only endpoint, or the write path getting it first). Page loads never fetch it.
  This is part of the write, not a page-view request, so it does not count against the budget.
- **Sign-in** (`auth:success`): discard the entry; the next page fetches fresh. **Sign-out** and
  401: discard the entry (as today).

### 4. Same-device changes made on Rails pages (my call — see below)

Some changes happen on normal (uncached) Rails pages rather than through the widgets: editing lists
on `/my/lists`, a Goodreads import, a Stripe checkout or portal returning to the site. Uncached
responses may set a small cookie carrying the user's current state version (e.g. `tg_state_v`).
On the next page load, if that cookie's version differs from the entry's, the browser treats the
entry as stale and re-checks (subject to the budget rule). This gives near-instant updates on the
same device at zero extra request cost, and is only ever written on uncached responses.

## Constraints

- Public repository: assume attackers read this. The combined endpoint returns only the signed-in
  user's own data; `tg_uid` and the version cookie are presentation hints, never trusted
  server-side.
- No Set-Cookie on an edge-cacheable response (`request.session_options[:skip]`).
- Rails 8 conventions, Result-pattern services, Minitest + Playwright per AGENTS.md.
- Music and games are live on the same app; the change ships to all three sites.

## Testing

- Rails: the combined endpoint's payload, 401, session renewal, ETag/304, and that the version
  changes for each kind of change (add item, remove item, create/delete list, membership granted,
  membership expired).
- Playwright per domain (books, music, games):
  - a signed-in reader navigating several pages within the hour makes **zero** state requests after
    the first;
  - a book show page makes exactly one Rails state request (`/review_state`), also when the hourly
    re-check is due;
  - adding to a list updates the widget and survives a reload without a state fetch;
  - with the "last checked" time pushed back past an hour, the next page makes exactly one
    conditional request;
  - after sign-out and sign-in as a different user, nothing of the first user's state is shown.

## Calls made without Shane (check these)

- The combined endpoint replaces the two separate ones rather than keeping both.
- On book pages the hourly re-check is postponed to the next page instead of being combined into
  the `/review_state` response.
- The same-device version cookie (§4). Without it, a change made on `/my/lists` or a membership
  bought through Stripe could take up to an hour to show in the widgets on that same device.
- The CSRF token is fetched at write time, not page load.
- The budget counts page loads, not clicks; the re-check backs off on every page that already costs
  a request (book, contact, public goal pages, and uncached Rails pages), not just book pages.
- A page that cannot re-check and has no entry renders empty list widgets and fetches on first
  interaction.
- Download CSV keeps a click-time membership check against the combined endpoint.

## Left to the builder

- How the version is computed (e.g. a counter on the user bumped by list/membership changes, or a
  hash of the payload) — as long as it changes on every change, deletions included.
- Endpoint naming and whether old routes remain as aliases during the deploy.
- How the token-at-write-time fetch is shaped.
- Exact localStorage shape and migration from today's entry (discarding old entries is fine).
