# List Submissions

## Overview

Any visitor — signed in or not — can propose a list for books, games, or music (albums and
songs) through a public form at `/lists/new` on each domain. It is a **port** of a legacy books
feature: the legacy corpus carries 209 user-submitted lists, 152 of which are live on the site
today, and one contributor submitted 25 lists in a single day. Those numbers, not a guess, size
the rate limits below.

A submission never goes live directly. It lands as a `List` row with `status: unapproved` and
`submitted_at` set, waiting in the same admin queue that already handles admin-created,
not-yet-approved lists — a human decides whether it becomes `approved` or `active` (or gets
rejected).

Entry points are a "Submit a list" button on each domain's `/lists` index page
(`app/views/books/lists/index.html.erb`, `app/views/games/lists/index.html.erb`,
`app/views/music/lists/index.html.erb`), all pointing at the same shared controller.

This feature is modelled closely on the corrections feature (`docs/features/` has no
`corrections.md` yet, but `CorrectionsController`'s comments are the reference `ListSubmissionsController`
was written alongside) — the null_session/honeypot/edge-caching/rate-limit shape below repeats
almost line for line between the two.

## Request flow

```
GET  /lists/new                          -> ListSubmissionsController#new     (edge-cached, 24h)
POST /list_submissions                   -> ListSubmissionsController#create  (never cached)
GET  /lists/thanks                       -> ListSubmissionsController#thanks  (edge-cached, 24h)
```

One controller serves all three domains — `Current.domain` (set from the request host) picks the
layout, the allowed list types, and the `thanks`/`lists` redirect targets. `#create` is a single
POST to `/list_submissions` (not domain-namespaced); it works out which domain it's on the same
way.

```
#create
  |
  v
honeypot filled? --yes--> redirect to thanks (silent discard, same response as success)
  |no
  v
Services::Lists::SubmissionRegistry.resolve(domain, params[:list_type])   -- or the domain's
  |                                                                          lone type, if it has
  |                                                                          only one and no type
  |                                                                          was submitted
  v
Services::Lists::Submission.call(list_class:, attributes:, user:, submitter_email:, submitter_ip:)
  |  length caps -> duplicate-url check -> build + save (status: unapproved)
  v
success -> AdminMailer.new_list_submission(list).deliver_later -> redirect to thanks
failure -> re-render #new with @error, :unprocessable_entity
```

## The type registry, and why a submitted type never reaches `constantize`

`Services::Lists::SubmissionRegistry` (`app/lib/services/lists/submission_registry.rb`) is a
plain hash: which `List` subclasses each domain accepts.

```ruby
TYPES = {
  books: [::Books::List],
  games: [::Games::List],
  music: [::Music::Albums::List, ::Music::Songs::List]
}
```

Legacy resolved the submitted type with `params[:changeable_type].constantize` — an arbitrary
constant name taken straight from the request. Here, `SubmissionRegistry.resolve(domain, name)`
does `types_for(domain).find { |klass| klass.name == name }`: an unlisted or malformed name simply
returns `nil`, and the controller answers 400. The registry is also how the controller picks a
type when the form didn't render a picker at all — books and games have exactly one type, so the
form's radio group is skipped (`@submittable_types.many?` guards it in
`app/views/list_submissions/_form.html.erb`) — but a submitted `list_type` is *always* run through
`resolve`, even on those single-type domains, specifically so a hand-crafted POST naming another
domain's class (e.g. a books visitor POSTing `list_type=Music::Albums::List`) can't ride the
"only one type, skip validation" shortcut.

`SubmissionRegistry` also holds the type -> label mapping the picker's UI uses (`label_for`) and
the reverse lookup the mailer needs (`domain_for`) — see "Notifying the owner" below.

## Rate limiting

Two `rate_limit` buckets on `ListSubmissionsController#create`, both windowed to one hour, using
Rails 8's built-in controller-level rate limiting against the app's shared rate-limit store
(`Rails.application.config.x.rate_limit_store`):

| Bucket | Cap | Keyed on |
|---|---|---|
| Signed in | 30/hour | `current_user.id` |
| Anonymous | 10/hour | `visitor_ip` |

The signed-in cap is set high enough to clear the legacy corpus's heaviest single-day contributor
(25 in a day, well under 30/hour) without being effectively unlimited. Anonymous submitters share
one bucket per IP and can't be individually identified, so they get the tighter cap — nothing an
anonymous flood produces is ever published, but triage still costs time, and a shared cap is the
only defense available for traffic with no other identity.

`by: visitor_ip`, never `request.remote_ip` — in production `remote_ip` is the shared Cloudflare
edge IP, so keying on it would put every anonymous visitor on the internet into the same bucket
and throttle the whole site after ten submissions from anyone, anywhere.
`app/controllers/concerns/visitor_ip.rb` reads `CF-Connecting-IP` first, falling back to
`remote_ip` only for requests that didn't come through Cloudflare (local dev, direct health
checks). Both `rate_limit` calls are declared with `store:` pointed at the same shared store, and
`with:` renders `#new` in place rather than redirecting — the redirect target (`/lists/new`) is
edge-cached, so a flash set on a redirect there would never be read by the visitor who tripped the
limit.

Declaration order matters: the two `rate_limit` calls are declared *after* `set_submittable_types`
in the controller body. `rate_limit` installs its own `before_action`, and Rails runs
`before_action`s in declaration order, so `@submittable_types` is already set by the time the
`with:` lambda re-renders `#new` on a 429.

## The honeypot and the `null_session` layering

A field named `website` is rendered off-screen (`position: absolute; left: -9999px`, not
`type="hidden"` — bots skip inputs of type hidden, but this one is a real text input a scraper's
form-filler happily fills). If it's non-blank on submit, `#create` redirects straight to the same
`thanks` page a real success would — the bot is told nothing went wrong, so there's no signal to
adapt against.

`#create` also sets `protect_from_forgery with: :null_session, only: [:create]`. The form page is
edge-cached, so its `<meta name="csrf-token">` belongs to whichever visitor's request populated
the Cloudflare cache — not to the person actually viewing it. A small Stimulus controller
(`shared--form-token`, shared with the corrections form) fetches a live token from `/form_token`
the first time the visitor focuses any field, and normally that's what's on the request by submit
time. `null_session` is the fallback for when it isn't (JS disabled, blocked, or just slow): rather
than showing the visitor a 422 they have no way to act on, the write is accepted as an anonymous
submission. This is safe specifically *because* the endpoint is already fully moderated — CSRF
protection exists to stop a forged request riding a signed-in victim's ambient session authority,
and `null_session` strips exactly that authority from the request before it's processed. What
lands is indistinguishable from a submission the same requester could have POSTed directly with
curl, and nothing it produces is visible anywhere until an admin approves it.

## Edge caching

`#new` and `#thanks` are cached at Cloudflare for 24 hours (`Cacheable#cache_for_show_page`,
`stale_while_revalidate: 1.hour`) with the session cookie skipped so the cache isn't bypassed by
`Set-Cookie`. `#create` explicitly disables caching (`Cacheable#prevent_caching`) since it's a
write. Because the cached page is identical for every visitor, the form's markup can't branch on
`current_user` — the "Your email" field is always rendered, and `#create` simply ignores whatever
it contains when the submitter turns out to be signed in.

`/lists/new` isn't yet inside a Cloudflare Cache Rule that ignores query strings, unlike the
correction form. Without one, `/lists/new?utm_source=x` and `/lists/new?utm_source=y` are distinct
cache keys, so a link carrying tracking parameters (or a scraper varying them) fragments the cache
almost for free. That's a Cloudflare dashboard change, not a code change, and it's a real but
lower-priority gap than it sounds — the correction form is linked from roughly 156,000 book pages
and has actually been used to flood the origin; this form is linked from three list index pages.

The three route declarations (`get "lists/new"`, `get "lists/thanks"`) are deliberately declared
*outside* each domain's `scope "(/rc/:ranking_configuration_id)"` block, and constrained to
`format: /html/`. `ListSubmissionsController` never loads a ranking configuration, so an
`/rc/:id/lists/new` URL or a `.json` suffix would otherwise render 200 for any value of that
segment — every distinct value being a fresh Cloudflare cache key and a fresh render at origin,
with no controller ever getting a chance to reject it. Routing them out entirely means the router
itself returns no route, before a request reaches Rails.

## robots.txt

`public/robots.txt` disallows `/lists/new` and `/lists/thanks` outright, alongside the existing
`Disallow: /*/suggest-correction` for corrections. Both pages already set `@indexable = false`,
which each domain's layout turns into `noindex, follow` — but books treats the robots meta tag as
opt-in while music and games treat it as opt-out (a global setting doesn't hide it on books
alone), so the `robots.txt` rule is the belt to that `@indexable` braces: it holds regardless of
which layout rendered the page or whether a future edit to one layout's meta-tag logic slips.

## Caps, and where they live

`Services::Lists::Submission::CAPS` (`app/lib/services/lists/submission.rb`) bounds `name` (255),
`source` (255), `url` (2,000), `description` (5,000), and `raw_content` (100,000) — plus a
separate `MAX_EMAIL_LENGTH` (255) for the anonymous submitter-email field, which isn't a column
the service writes to `attributes` at all. These caps live in the *service*, not on the `List`
model, on purpose: production `raw_content` (admin-pasted list content, fed into the list wizard)
reaches 1,568,804 characters on the admin path, so a model-level validation would break admin
usage. Only the public endpoint needs to be bounded, so the bound is enforced only where the
public endpoint's code runs.

An oversized field is **rejected**, never silently truncated — `cap_errors` re-renders the form
with a validation message rather than saving a half-written submission the visitor has no way to
know was cut short. The nil-vs-blank distinction in that check is deliberate too: it tests
`value.nil? || value.to_s.length <= cap`, not `value.blank?`, because `String#blank?` is true for
an all-whitespace string of *any* length — using it would let 100,001 spaces of `raw_content` skip
the cap and save unbounded.

`Services::Lists::Submission::PERMITTED` is the complete allowlist of fields the public form can
set. Everything else — `status`, `submitted_by_id`, `estimated_quality`, and every ranking-weight
field the admin form exposes — is silently dropped from whatever the request sends, because those
aren't the submitter's to choose. (Legacy's form permitted all of them; this one's template simply
never renders inputs for them, and the service enforces that at the parameter layer too, so a
hand-crafted POST can't reach past the template to set them either.)

## Duplicate detection

`Submission#duplicate?` is a courtesy, not an invariant. It normalizes the submitted URL (strip,
downcase, drop a leading `http(s)://` and `www.`, drop a trailing slash) and compares it in Ruby
against every non-blank URL already on lists of the *same* type — scoped by type because, for
example, the same page can legitimately be the primary source for both a music albums list and a
music songs list. There's no unique index backing this: 22 existing (type, url) pairs are already
duplicates in the data, so one can't be added without a cleanup pass first. A match short-circuits
`Submission.call` with `DUPLICATE_MESSAGE` ("We already have this list — thanks for checking.")
before anything is built or saved.

## Notifying the owner

On a successful save, `AdminMailer.new_list_submission(list).deliver_later` (never `deliver_now`
— legacy sent this synchronously in the request, blocking the submitter on the mail provider with
no retry). The mailer runs in Sidekiq, where `Current.domain` is `nil`, so it resolves branding via
`Services::Lists::SubmissionRegistry.domain_for(list.class)` rather than the request-scoped
domain — the reason `domain_for` exists on the registry at all. The email's `reply_to` prefers the
signed-in submitter's account address over the typed `submitter_email`, since the former is
verified and already on file.

`ADMIN_NOTIFICATION_EMAIL` must be set or the mailer raises `AdminMailer::MissingAdminAddress` —
the corrections and membership mailers already require it, so it's very likely already configured,
but that's worth confirming rather than assuming on any environment this ships to.

## Finding and processing a submission as an admin

Each domain's admin lists index (`Admin::Lists::IndexComponent`) has a "User submitted" filter
alongside the existing status filter, driven by `submitted_at`. It's a distinct signal from
"unapproved" — 1,721 of 1,772 unapproved lists in the corpus are ordinary admin import backlog
with no submitter at all, and `submitted_at` is set *only* by this public form, so it's what
separates a submission queue from the general backlog. The table and show page display who
submitted a list as `submitted_by&.email || submitter_email.presence || "Anonymous"`.

From there, review is the same admin list-editing flow as any other list: open the show page,
check the pasted `raw_content` / description / source, and change `status` (via the edit form) to
`approved`, `active`, or `rejected`. `submitter_ip` is stored on the record
(`app/lib/services/lists/submission.rb` sets it from `visitor_ip`) but isn't currently surfaced in
the admin UI the way it is on a correction's show page.

## Key files

| File | Role |
|---|---|
| `app/controllers/list_submissions_controller.rb` | `new`/`create`/`thanks`; rate limiting, honeypot, edge-caching, type resolution |
| `app/lib/services/lists/submission_registry.rb` | domain -> allowed `List` subclasses; the only place a type name is resolved to a class |
| `app/lib/services/lists/submission.rb` | length caps, duplicate check, builds and saves the `unapproved` `List` |
| `app/controllers/concerns/visitor_ip.rb` | `CF-Connecting-IP`-first IP resolution, shared by every IP-keyed rate limit |
| `app/controllers/concerns/cacheable.rb` | the `expires_in`/`prevent_caching` helpers behind the edge-caching split |
| `app/views/list_submissions/_form.html.erb` | the shared form; `aria-label`s label every input since daisyUI 5's `fieldset`/`legend` doesn't |
| `app/mailers/admin_mailer.rb` (`new_list_submission`) | owner notification, `deliver_later` |
| `app/components/admin/lists/index_component.*` | the admin "User submitted" filter |
| `db/migrate/20260829171537_add_submission_fields_to_lists.rb` | adds `submitted_at`/`submitter_email`/`submitter_ip`, backfills `submitted_at` for the 209 legacy rows |
| `e2e/tests/books/list-submission.spec.ts` | anonymous submit-to-thanks flow; the `<details>` panel opening on click |

## Related documentation

- `docs/features/e2e-testing.md` — the Playwright harness this feature's spec runs under
- `docs/features/list-wizard.md` — what happens to `raw_content` once a list is approved on
  domains with the admin wizard
