# Corrections — design

Reader-submitted data corrections, replacing the legacy site's `changesets` feature. A public form
on each record's page collects proposed fixes; an admin queue reviews, edits and applies them; an
email notifies the owner on each submission. Built domain-agnostic, with books wired first.

A future increment will have an agent research and apply corrections automatically through an MCP
server. That is out of scope here, but it is why the apply path is a real, tested service rather
than an admin-only code path.

## What legacy does today

`the-greatest-books/admin`:

- `changesets` table: polymorphic `changeable`, `change_data` jsonb of `{field: {from:, to:}}`,
  free-text `notes`, `status` enum, optional `user`.
- A `Changeable` concern. `changeable :title, :sub_title, …` declares which of the model's own
  columns may be proposed. `changed_attributes` diffs submitted values against current ones;
  `apply_changes` writes them and calls `save!`.
- Public: `ChangesetsController#new` renders every declared field pre-filled with its current value
  plus a notes box. `#create` diffs, saves, emails `contact@thegreatestbooks.org` synchronously,
  redirects.
- Admin: a flat table of every changeset ever, newest first, and a show page with two buttons —
  Apply and Delete.

### What is wrong with it

1. `approved` and `rejected` are declared and never set. `rejected_at` is never written. The only
   disposal is Delete, which destroys the audit trail along with the row.
2. Apply is all-or-nothing. A submission with a good title fix and a bogus year is applied whole or
   discarded whole, and there is no way to correct a near-miss.
3. No conflict detection. `from` is captured at submit time; if the record changed since, apply
   silently overwrites the newer value.
4. The index has no status filter, no search and no scoping.
5. Only scalar columns are representable. Authors, countries and genres are not — the form's own
   copy tells the reader to describe those in the notes box.
6. `params[:changeable_type].constantize` resolves an arbitrary constant from a request param.
7. The email is built and sent inline in the request. Blocking, no retry.
8. Anonymous public write endpoint with no rate limit and no spam control.
9. **The `new` page is uncached and has been used to DDoS the live site** — a flood of GETs, each
   rendering the full Rails stack, took the site down.

### The legacy data

448 rows: 236 `pending`, 212 `applied`. Every one targets `Book`; none targets `Author`. Ids 1–647,
submitted between 2024-10-16 and 2026-07-02, so it is still receiving traffic.

Of the 236 pending: 82 are anonymous, 175 carry notes, and **111 are notes-only with no field
proposals at all**. Notes are the primary content in this data, not a fallback.

Field proposals across all 448:

| legacy field | count | new-app target |
|---|---|---|
| `first_year_published` | 86 | `first_published_year` (column) |
| `description` | 68 | `Description` row, `source: :manual` |
| `title` | 61 | `title` (column) |
| `alternate_titles` | 50 | `alternate_titles` (column) |
| `sub_title` | 47 | `subtitle` (column) |
| `page_range` | 38 | `page_range` (column) |
| `word_count` | 13 | `word_count` (column) |
| `series_name` / `series_number` / `series` | 20 | none — association now; folded into notes |
| `original_language` | 2 | none — association now; folded into notes |

Two changesets point at books that no longer exist.

## Scope

In scope: the shared machinery, `Books::Book` as the first correctable record, the public form, the
admin queue, the owner email, and the legacy migration.

Out of scope: agent/MCP automation; association corrections (authors, countries, categories, series,
original language) as structured proposals; `Books::Author` and other records; music and games
wiring beyond proving it is a config change.

## Data model

Two tables. Legacy kept everything in one `change_data` blob; per-field accept/edit/reject needs a
decision recorded per field, and nested decision state inside jsonb cannot be indexed, cannot be
validated, and forces every read to defend against missing keys.

```
corrections
  correctable_type, correctable_id   not null, polymorphic
  user_id                            nullable, FK users      -- nil = anonymous
  notes                              text
  status                             integer not null default 0
  resolved_by_id                     nullable, FK users
  resolved_at                        datetime
  resolution_notes                   text
  submitter_ip                       string, nullable        -- spam triage only
  timestamps

  index (correctable_type, correctable_id)
  index (status, created_at)

correction_fields
  correction_id                      not null, FK corrections
  field_name                         string not null
  old_value                          jsonb                   -- record's value at submission
  new_value                          jsonb                   -- what was proposed
  status                             integer not null default 0
  applied_at                         datetime
  timestamps

  index (correction_id)
  unique index (correction_id, field_name)
```

`jsonb` for the values because the field set spans integers (`first_published_year`), strings
(`title`, `page_range`) and a string array (`alternate_titles`). jsonb round-trips all three without
a cast-on-read guess.

### Statuses

`Correction#status`: `pending` (0), `resolved` (1), `rejected` (2).
`CorrectionField#status`: `pending` (0), `applied` (1), `rejected` (2).

`resolved` means the admin acted — whether by applying fields or by fixing something described in
the notes by hand. The field rows record which. There is deliberately no `approved` state: nothing
sits between approving a field and writing it, and legacy's unused `approved`/`rejected` pair is the
warning.

## The `Correctable` contract

Modelled on `Reviewable` and `Describable`, the two shared polymorphic contracts this codebase has
already converged on.

```ruby
class Books::Book < ApplicationRecord
  include Correctable

  correctable_field :title,                type: :string
  correctable_field :subtitle,             type: :string
  correctable_field :first_published_year, type: :integer
  correctable_field :page_range,           type: :string, hint: "A number or a range, e.g. 300 or 250-350"
  correctable_field :word_count,           type: :integer
  correctable_field :alternate_titles,     type: :string_array
  correctable_field :description,          type: :text, target: :description
end
```

The declared `type:` is the allowlist entry, the cast rule and the choice of form input at once.
Legacy instead read `columns_hash[field].sql_type_metadata.sql_type` and pattern-matched the SQL
type string, logging an error and silently rejecting anything it did not recognise. Declaring it is
shorter and cannot drift from the column.

`CorrectionField` validates `field_name` against the declared set for its correction's record, so an
undeclared field cannot be stored.

### Target strategies

`target:` defaults to `:column`. There are exactly two:

- `Services::Corrections::Targets::Column` — reads `record.public_send(field)`; writes
  `record.public_send("#{field}=", value)`.
- `Services::Corrections::Targets::Description` — reads `record.primary_description&.content`;
  writes a `Description` row with `source: :manual`, which `Descriptions::Resolver` then prefers
  over the Wikipedia or OpenLibrary one.

Description is a target rather than a column because `books_books.description` is not read on any
book page any more and is scheduled for deletion as the last step of the descriptions subsystem.
It earns the special case: 68 of 448 legacy corrections propose one, the second-largest category.

### Fields deliberately excluded

`sort_title`, `book_kind`, `book_length` — not visible to a reader, so a reader cannot know they are
wrong. `book_length` is derived.

### Known consequence

`Books::Book#derive_book_length` runs only when `book_length` is blank. Applying a `page_range` or
`word_count` correction to a book that already has a length would otherwise leave the Length and
Pages rows contradicting each other on the public page. The applier recomputes it explicitly.

## Type resolution

`params[:correctable_type]` never reaches `constantize`. It resolves through
`Admin::DomainRouting::ENTITIES`, which already maps `"Books::Book" => {domain: :books, path: …}`
for descriptions and category items. An unknown type is a 400. The registry is also what supplies
the domain for scoping, mail branding and admin auth.

## Public interface

### Entry point

A plain GET link, "Suggest a correction", below the Details card on the book page. It must be a link
and not a form: that page is edge-cached 24h with `session_options[:skip] = true`, so it carries no
session and no usable CSRF token.

### Route

```ruby
get "book/:slug/suggest-correction", to: "corrections#new",
    defaults: {correctable_type: "Books::Book"}, as: :books_book_correction
```

Inside the books domain constraint. The type comes from route defaults, not from a param, so `#new`
trusts nothing. Music and games each add one analogous line pointing at the same shared controller.

### The form page

`cache_for_show_page` — the same 24h public cache and skipped session as the book page. This is the
fix for the DDoS: the page stops reaching Rails.

**This requires a Cloudflare Cache Rule that ignores query strings on `/book/*/suggest-correction`.**
Without it, `?x=1`, `?x=2` … are distinct cache keys and every request is a miss straight through to
Rails. The rule is the load-bearing half; the cache headers alone do not fix anything.

Not indexed: `@indexable = false` (the books layout emits `noindex, follow` unless it is truthy, so
this is belt-and-braces), plus `Disallow: /book/*/suggest-correction` in `robots.txt`.

Layout, in order:

1. Cover, title and authors, so the reader can see what they are correcting.
2. **"Tell us what's wrong"** — a textarea, first and prominent. This is the primary path: 111 of
   236 pending legacy submissions are notes-only, and everything structural — authors, genres,
   countries, series, original language — can only be expressed here.
3. **"Or correct these details"** — one labelled input per declared field, prefilled with the current
   value. `page_range` shows its hint inline. `alternate_titles` is a repeatable add/remove list.
   `description` is a textarea prefilled with whatever description the page currently displays.

Full-page rather than a modal: seven fields including two textareas and a repeatable list does not
fit a dialog on mobile.

### CSRF, in two layers

The page is cached, so its rendered `<meta name="csrf-token">` belongs to whoever populated the
cache, or to nobody. Neither layer can produce a token error for the user.

1. `GET /correction_token` — uncached, returns `{csrf_token: form_authenticity_token}` and issues a
   session. No database query; the cheapest endpoint in the app. A small Stimulus controller fetches
   it **on first interaction with the form** (focus or input) and writes it into the hidden field.
   Fetching on interaction rather than on load means a crawler or a flood that never touches the
   form never reaches this endpoint. Same shape as `/review_state` and `/membership_state`, minus
   the state.
2. `protect_from_forgery with: :null_session` on `#create`. If that fetch never happened — JS off,
   blocked, slow, ad blocker — the POST is accepted as an anonymous submission rather than raising.

Layer 2 is sound, not a compromise. CSRF exists to stop a forged request riding a victim's ambient
session authority; `null_session` removes exactly that authority. What lands is an anonymous
correction the attacker could have submitted directly, and it is moderated before it touches a book.
The only cost is losing attribution for a signed-in user whose token fetch failed.

### Create

Shared `CorrectionsController#create`:

- Resolves the type through the registry allowlist.
- Re-reads the record and derives `old_value` server-side from the **current** record. A submitted
  `from` is never trusted.
- Casts each submitted value to its declared type and compares against the current value; creates a
  `correction_fields` row only for values that actually moved.
- Rejects a submission with neither notes nor a single moved field.
- Redirects back to the record with a confirmation.

### Spam controls

- A named rate-limit bucket, `by: -> { current_user&.id || visitor_ip }`, on
  `Rails.application.config.x.rate_limit_store`.
  **`visitor_ip` must read `CF-Connecting-IP`.** `request.remote_ip` in production is the Cloudflare
  edge IP, so an IP-keyed limit on it puts every visitor in one bucket and throttles the whole site
  at the fifth submission. `MembershipController#visitor_ip` already solves this privately; lift it
  into a shared concern and have both use it.
- `with:` a redirect, never Rails' default raise, which renders an HTML error body.
- A honeypot field: filled means accept-and-discard, so the bot receives a 200 and does not retry.
- Length cap on notes; field rows capped at the declared field count.

## Admin interface

Per-domain index at `/admin/books/corrections`, shared controller, one entry in
`Admin::DomainNav::CONFIGS[:books][:items]`. Auth via `Admin::DomainScopedAuth` with
`domain_auth_parent` resolving to the correction's record, matching `Admin::DescriptionsController`.

### Index

- Defaults to **pending**. Status tabs with counts: Pending / Resolved / Rejected.
- Scoped to the current domain via the registry, so books admin sees only books corrections.
- Per row: the record (linked to both its admin page and its public page), a compact summary of what
  is proposed (`Year 1948→1949 · Title · notes`), submitter or "Anonymous", age.
- Text search across notes. Pagy pagination.
- **Bulk reject.** 82 of the 236 pending are anonymous and some of that backlog is junk; clearing it
  should be one action.

### Show

- **Notes first, full width.** 111 of 236 pending corrections are notes-only.
- A field table with three columns, not legacy's two: **Was** (at submission), **Is now** (live from
  the record), **Proposed**. With a backlog reaching back to Oct 2024 over books that have since
  been through the description migration and Amazon enrichment, a stale `Was` is the normal case
  here. A row where *Was* ≠ *Is now* is flagged rather than silently overwritten.
- Each row: a checkbox to accept, and the proposed value in an editable input, so a near-miss is
  corrected rather than rejected.
- Actions: **Apply selected**, **Reject** (with an optional reason into `resolution_notes`), and
  **Mark resolved** for a notes-only correction fixed by hand.
- **No Delete.** Rejected corrections stay; legacy's only disposal destroyed the audit trail.

### Apply

`Services::Corrections::Applier.call(correction:, accepted:, admin:)`, returning the repo's standard
`Result` struct, in one transaction:

- Column fields are assigned and written with a single `save!`.
- The description field writes a `Description` row with `source: :manual`.
- Accepted field rows become `applied` with `applied_at`; unchecked rows become `rejected`; the
  correction becomes `resolved` with `resolved_by` and `resolved_at`.
- `book_length` is recomputed when `page_range` or `word_count` changed.
- An invalid record rolls the whole transaction back and surfaces the real validation errors.
  Legacy collapsed every failure into one generic "Failed to apply changes".

Reindexing rides the record's existing `SearchIndexable` callback. The cache purge follows the
pattern already in `ReviewsController#purge_cached_page`.

## Email

`AdminMailer#new_correction(correction)`, alongside `new_subscription` and `new_donation`. Branded
per domain via `MailBranding.for(domain)` with the domain from the registry, so a music correction
later arrives looking like music with no new plumbing. `deliver_later` onto Sidekiq, not inline.
`reply_to` the submitter when signed in. Both `.html.erb` and `.text.erb`, matching every other
mailer here.

Body: the record and a link to its public page, a link to the admin correction, the notes, the
proposed field table, submitter, submitted-at.

Recipient is `ENV["ADMIN_NOTIFICATION_EMAIL"]`, the existing owner-notification address used by the
membership and donation mailers. **Assumption to confirm before increment 4 ships:** that this
resolves to `contact@thegreatestbooks.org` in production. If corrections need a different address,
that is a second env var, not a design change.

The migration must not send 448 emails. `insert_all` bypasses callbacks, so this is safe by
construction — and gets a test.

## Legacy migration

`Services::BooksMigration::CorrectionMigrator` on the existing `InsertOnlyMigrator` base, with a
`data_migration:corrections` rake task wired into `:all`.

- Legacy changeset ids are preserved into `corrections` (1–647 into a new table, so it is free) —
  giving idempotency via `ON CONFLICT DO NOTHING` and traceability back to the legacy row. Then
  `reset_pk_sequence!`.
- Book ids and user ids are already preserved by `BookMigrator` and `UserMigrator`, so
  `changeable_id` and `user_id` map 1:1, with a set-membership check.
- `"Book"` → `"Books::Book"`.
- Status 0 → `pending`; 3 → `resolved`, with field rows `applied` at the legacy `applied_at`.
- Field renames: `sub_title` → `subtitle`, `first_year_published` → `first_published_year`. The rest
  carry over unchanged.
- Unmappable proposals — `series_name`, `series_number`, `series`, `original_language` — are folded
  into the correction's `notes` as a readable "From the old site" block showing field, from and to,
  so nothing is lost and the admin can act by hand.
- The two changesets whose book no longer exists are skipped with a logged warning rather than
  raising. This is a deliberate departure from `ReviewMigrator`'s fail-loud rule: a correction for a
  deleted book has nothing to correct.

## Increments

1. **Schema and contract.** Both tables, `Correction`, `CorrectionField`, the `Correctable` concern
   and `correctable_field`, the two target strategies, value casting. `Books::Book` declares its
   seven fields. Registry entries. No UI.
2. **Public submission.** Cached form page, token endpoint, Stimulus controller, create action, rate
   limit, honeypot, `null_session`, noindex, robots.txt, and the link on the book page. Playwright
   test. Cloudflare Cache Rule is an ops step alongside this.
3. **Admin review and apply.** Index with status tabs, search and bulk reject; show page with the
   three-column table and editable proposals; the `Applier` service; sidebar entry; domain auth.
   Playwright test.
4. **Email.** Mailer action and both templates.
5. **Legacy migration.** `CorrectionMigrator`, field renames, notes folding, orphan skip, rake task,
   then run against the real 448 in dev.
6. **Music and games.** One `include Correctable` plus field declarations per model, a registry
   entry, a sidebar entry, a route, a link. Last on purpose — it is the increment that proves the
   abstraction held.

## Testing

Minitest with fixtures and Mocha; Playwright for the two user-facing flows. Fixture names are
semantic — check them before referencing.

- Models: `Correction`, `CorrectionField`, the `Correctable` declaration and its allowlist
  validation, both target strategies.
- Services: `Applier` (column write, description write, invalid-record rollback, `book_length`
  recompute, stale-value flagging), value casting, `CorrectionMigrator` with `legacy_each` stubbed
  so the legacy connection is never opened.
- Public controller: anonymous create, signed-in create, honeypot discard, rate limit, the
  `null_session` path, cache headers on `#new`, noindex, and that `old_value` is derived server-side
  rather than from the submitted `from`.
- Admin controller: index scoping and status filtering, apply, partial apply, reject, bulk reject,
  domain auth and write permission.
- Mailer: content, branding, `reply_to`, and that the migrator sends nothing.
- E2E: submit a correction from a book page as an anonymous visitor; apply one from the admin.

Two traps to watch. `assert_empty` passes against deleted code — every new test gets its subject
deleted once to confirm it goes red before the test is trusted. And `eager_load` is off in test, so
`CI=1 bin/rails zeitwerk:check` runs after adding `app/lib/services/corrections/`.

## Open questions

- Does `ENV["ADMIN_NOTIFICATION_EMAIL"]` resolve to `contact@thegreatestbooks.org` in production?
  Blocks increment 4 only.
- The Cloudflare Cache Rule ignoring query strings on the correction path is an ops change that must
  land with increment 2, or the DDoS fix is not a fix.
