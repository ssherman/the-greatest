# Contact form — design

A contact form in a modal, opened from the footer link that is currently a `mailto:`. Replaces the
legacy books site's contact form. Signed-in visitors get their email prefilled; anonymous visitors
type one, which becomes the `Reply-To`. Each submission is stored and emailed to
`contact@thegreatestbooks.org`, branded with the site it came from.

Unlike legacy, submissions are **persisted**. That is the one deliberate departure, and the reason
is forward-looking: the eventual goal is an agent that drafts replies, and an agent needs a queue to
work through, not an inbox it cannot see.

## What legacy does today

`the-greatest-books/admin`:

- `DefaultController#load_contact_form` renders a Turbo Frame containing a form: an email field and
  a message textarea. Signed in, the email field is `disabled` and its value duplicated into a
  hidden field. Anonymous, the field is empty and labelled "Your Email (optional)".
- `DefaultController#contact` builds an `Email` object inline, sends it to
  `contact@thegreatestbooks.org` with `reply_to` set to the submitted address, and returns
  `head :no_content`. The subject is the message truncated to 100 characters.
- A Stimulus controller closes the Bootstrap modal on `turbo:submit-end` and shows a Notiflix toast.
- Nothing is stored.

### What is wrong with it

1. **Nothing is stored.** A delivery failure loses the message with no trace, and there is no queue
   an agent could ever read.
2. `skip_forgery_protection` on the whole controller, and no rate limit or spam control on an
   anonymous public write endpoint.
3. The email is built and sent inline in the request — blocking, with no retry.
4. The submitted email is trusted even when the visitor is signed in. The `disabled` field is
   cosmetic; the hidden field beside it is editable by anyone with devtools.
5. No indication of which site the message came from — legacy is single-site, so it never needed one.
   This app is not.

## Design

### The edge-cache constraint

Every public page in this app is Cloudflare-cached, and the footer is on every one of them. The
cached HTML is whichever visitor's copy populated the cache. Two consequences drive the whole
client-side design:

- The form **cannot be rendered with the signed-in visitor's email in it**. Doing so would serve one
  person's address to every subsequent visitor. The footer must render byte-identical HTML for
  everyone.
- The `<meta name="csrf-token">` in the page belongs to a stranger or to nobody.

Both are solved the way `CorrectionsController` already solves them: an uncached endpoint the client
calls on demand. `GET /contact_state` returns `{email:, csrf_token:}` — the email is
`current_user&.email`, null when anonymous. It does no database query beyond loading the session,
and it is called **when the modal opens**, not on page load, so a crawler that never opens the modal
never reaches it.

### Trust boundary

`POST /contact_messages` reads `current_user.email` and **ignores the submitted email field** when
the visitor is signed in. The prefill is a convenience; the server decides. Only an anonymous
submitter's typed address is stored, and it is stored as the reply address, never used to
authenticate anything.

### Two decisions legacy made differently

**The email is required, for everyone.** Legacy labels it "Your Email (optional)" and accepts a
blank one, which produces a message nobody can answer — the `Reply-To` is empty and the sender is
untraceable. The owner has hit this directly: replies that cannot be sent. A contact form whose
entire purpose is a reply channel should not accept submissions that cannot be replied to, and an
unanswerable message is also worthless to an agent that drafts replies. Hence `null: false` on the
column, plus presence and format validations. The cost is one more required field for anonymous
visitors.

The format validation catches the honest typo (`shane@gmail`, a missing TLD), not the deliberate
fake — nothing here verifies that an anonymous address exists, and nothing should try to for a
contact form. Signed-in submissions carry a Firebase-verified address and need no such caveat.

**The modal stays open on success and shows a confirmation in place.** Legacy closes the modal and
raises a Notiflix toast. This app has no toast on public pages and public layouts render no flash,
so swapping the modal body to a "Thanks — we'll get back to you" panel with a close button is both
simpler and the only mechanism actually available here.

### Data model

One table, `contact_messages`, global namespace — it is cross-domain, like `Correction` and
`NewsPost`, not media-specific.

| column | type | notes |
|---|---|---|
| `email` | string, not null | `current_user.email` when signed in, otherwise the typed value |
| `message` | text, not null | capped at 10,000 chars — the same bound `Correction` puts on notes |
| `domain` | integer, not null | enum, see below |
| `user_id` | bigint, nullable, FK | null for anonymous |
| `submitter_ip` | string, nullable | spam forensics, as on `Correction` |
| `status` | integer, not null, default 0 | `pending` / `replied` / `spam` |
| `replied_at` | datetime, nullable | |

Indexes: `[status, created_at]` for the admin queue, `[domain, created_at]` for the per-domain
scoping, `user_id`.

```ruby
enum :domain, {music: 0, games: 1, books: 2}
enum :status, {pending: 0, replied: 1, spam: 2}
```

The `domain` integers deliberately match `NewsPost`'s mapping so the two do not disagree about what
`1` means. `status` has no `new` value — Rails generates a scope per enum value and
`ContactMessage.new` would collide with the constructor.

**Named `ContactMessage`, not `Contact`.** `SiteContact`'s comment reserves the name `Contact` for
this model, but pairing a `Contact` model with a `Services::Contact::` namespace is the sibling
constant shadowing that broke 95 tests during the Amazon work. `ContactMessage` +
`Services::ContactMessages::` has no overlap.

**Deliberately absent:** no `subject` and no name field — the legacy form is email and message, and
this keeps it identical. No `replied_by_id` — on a single-owner site it records nothing. That column
becomes worth adding when an agent starts drafting replies and you need to tell its replies from
your own.

### Service

`Services::ContactMessages::Submission.call(email:, message:, user:, domain:, submitter_ip:)`,
returning the project's `Result` struct. Resolves the email (`user&.email` wins), builds and saves
the record, enqueues the mail. Business logic lives here rather than in the controller, per the
project's skinny-models/fat-services rule — and it is where an auto-reply path would later attach.

### Mail

`AdminMailer#contact_message(contact_message)`, using the existing `branded_mail`:

- **To** `SiteContact::ADDRESS` (`contact@thegreatestbooks.org`), *not*
  `ENV["ADMIN_NOTIFICATION_EMAIL"]`. That variable is where sales and donation alerts go; the footer
  already advertises the contact address publicly, so the form and the `mailto:` land in the same
  inbox.
- **Reply-To** the submitter's address, exactly as `new_correction` does it.
- **Subject** `Contact via <site name>: <message truncated to ~60 chars>`. Legacy's
  truncated-message subject is genuinely useful for inbox triage; the site name prefix is the
  "which site is this from" answer. `MailBranding.for(domain).site_name` supplies it, and the
  template is rendered in that site's brand colour.
- `deliver_later`, so a mail outage retries in Sidekiq rather than blocking the submitter. The row
  is already saved by then either way.

No auto-reply copy to the submitter. Legacy sends none and none was asked for.

### Public endpoints

Both global (not domain-constrained), alongside the correction endpoints in `config/routes.rb`:

```ruby
get "contact_state", to: "contact_state#show", as: :contact_state
resources :contact_messages, only: [:create]
```

`ContactStateController` mirrors `CorrectionTokenController`: `include Cacheable`,
`before_action :prevent_caching`, renders JSON, no database work.

`ContactMessagesController#create`:

- `protect_from_forgery with: :null_session` — same reasoning as corrections. If the token fetch
  never happened (JS off, blocked, slow), the write lands as anonymous rather than showing a 422 the
  submitter cannot act on. Null session removes exactly the ambient authority CSRF protects, so what
  gets through is a message the attacker could have posted directly, into a queue that is read by a
  human before anything happens.
- **Honeypot** on `params[:website]`. Filled means discard silently — and still return the ordinary
  thank-you, because a 200 stops a bot retrying where a 422 brings it back.
- **Rate limits** keyed through the `VisitorIp` concern, never `request.remote_ip`, which in
  production is the Cloudflare edge IP and would put every visitor in one bucket:

  | bucket | limit | key |
  |---|---|---|
  | anonymous | 5 / hour | `visitor_ip` |
  | signed in | 20 / hour | `current_user.id` |

  These are guesses, not measurements — legacy never stored contact messages, so there is no history
  to derive them from. They are cheap to change.
- Responds with **`turbo_stream` in every case** — success, validation failure, and rate-limited —
  replacing `#contact_modal_body`. A bare `head :unprocessable_entity` blanks the page, and public
  layouts render no flash at all, so a turbo-stream swap is the only way to tell the submitter what
  happened.

### Footer and modal

The dialog lives in `FooterComponent`, not in the three layouts — one file already serves books,
music and games, which is why the footer was consolidated into a component in the first place.

- `site_links` stops returning `["Contact", SiteContact::MAILTO]`. The Site column renders the other
  entries as links and Contact as a `<button class="link">`, so it looks identical to its siblings.
- The `mailto:` on the privacy and deletion policy pages **stays**. `/deletion_policy` is Facebook's
  data-deletion URL and has to carry a reachable address in the page itself.
- Markup: a `<dialog id="contact_modal" class="modal">` holding `#contact_modal_body`, which is what
  the turbo-stream replaces.
- daisyUI 5: `fieldset` + `fieldset-legend`, bare `input` and `textarea`. None of
  `form-control` / `label-text` / `textarea-bordered`, which are v4 classes that fail silently and
  are caught by `test/lint/daisyui_v4_classes_test.rb`.

### Stimulus

One controller, `controllers/contact/form_controller.js`, registered as `contact--form` in
`manifests/web_shared.js` — the manifest all three public domains import, so one registration covers
books, music and games. `test/lint/stimulus_manifest_test.rb` checks registrations against markup in
views and components; `FooterComponent` is a component, so it is covered.

`data-controller="contact--form"` goes on a wrapper containing both the button and the dialog, so
the button's click can do two things:

```
open()  ->  dialogTarget.showModal()  +  ensureState()
```

`ensureState()` fetches `/contact_state` once per page, guarded against concurrent calls, and:

- writes `csrf_token` into the form's `authenticity_token` input **and** patches the page's
  `<meta name="csrf-token">`, since the cached page's token is stale for every other Turbo request
  on the page too — same as `corrections/form_controller.js` and `reviews/widget_controller.js`;
- if `email` came back, fills the email field and marks it read-only; if not, leaves it editable.

A failed fetch shows no error and blocks no submit — `null_session` accepts the write as anonymous,
and losing attribution beats a 422 the submitter cannot act on.

This fires on open rather than on first focus (which is what corrections does) because a signed-in
visitor should see their address already in the field, not watch it appear after they click
elsewhere. The cost is one request per modal open instead of per form interaction, on a modal that
is opened deliberately.

### Admin

Split per site, following `Admin::CorrectionsController`.

- `Admin::ContactMessagesController < Admin::BaseController`, scoped to `current_domain`. Guarded by
  the inherited `authenticate_admin!`; corrections has no policy object and neither does this.
- Routes in all three admin namespaces, with an `ADMIN_PATHS` map as corrections has:
  `admin_contact_messages_path` (music), `admin_books_contact_messages_path`,
  `admin_games_contact_messages_path`.
- A **Contact** entry in `Admin::DomainNav::CONFIGS` for books, music and games. That registry is
  the only place an admin sidebar link exists.
- `index` defaults to `pending` with status counts and filters, like the corrections queue.
  `show` renders the message with a `mailto:` reply link and buttons to mark it replied or spam.
- The message body is visitor-supplied text, so it needs `overflow-wrap: anywhere` — `break-words`
  does not fix long unbroken strings.

## Testing

- **Model** — validations, the 10,000-char cap, both enums.
- **Service** — `Result` success and failure; the signed-in email overrides a submitted one.
- **`ContactMessagesController`** — signed-in submission stores `current_user.email` and ignores the
  typed value; anonymous stores the typed value; a filled honeypot persists nothing and still
  returns the thank-you; both rate-limit buckets; success, failure and throttle all return
  turbo-streams. Behaviour only — status codes and persisted state, never markup or copy.
- **`ContactStateController`** — email present signed-in, null anonymous, token always present,
  no-store headers set.
- **`AdminMailer#contact_message`** — recipient, `Reply-To`, site name in the subject, and that each
  domain renders its own branding.
- **`FooterComponent`** — the assertion that actually matters: the rendered footer HTML is
  **identical signed-in and signed-out**. This is what catches a later "improvement" that prefills
  the form server-side and poisons the Cloudflare cache with one visitor's address.
- **Admin** — domain scoping (a books message must not surface in music's queue) and status
  transitions.
- **Playwright** — open the modal from the footer, submit anonymously, see the confirmation; and the
  signed-in prefill path.

Two habits, both earned here: no `assert_empty` as a load-bearing assertion, and every new test gets
verified by deleting the line it covers and watching it go red. Component assertions use exact
matching — Capybara's `text:` is a substring match and has produced vacuous passes in this repo.

## Increments

1. Migration, `ContactMessage`, `Services::ContactMessages::Submission`,
   `AdminMailer#contact_message`. No UI.
2. `GET /contact_state` and `POST /contact_messages` — rate limits, honeypot, turbo-stream responses.
3. Footer modal, `contact--form` Stimulus controller, manifest registration.
4. Admin controller, views, routes, three `DomainNav` entries.
5. Playwright specs and `docs/features/contact_form.md`.

## Risks

- The footer ships to **music and games, which are live**. Books is pre-launch, but a footer defect
  is visible on all three the moment this merges.
- The rate-limit numbers are guesses, as noted above.
- The migration creates one new table with no backfill, so it carries none of the
  failing-migration-is-an-outage risk.

## Out of scope

- Agent-drafted replies. The schema is shaped to accept them; nothing here implements them.
- A standalone `/contact` page. Modal only, as on legacy.
- An auto-reply to the submitter.
- Migrating historical contact messages — legacy stored none.
