# List audits

Spec: `docs/superpowers/specs/2026-11-21-admin-mcp-list-audits-design.md`. Books only. An admin's AI agent works through the books lists one at a time, checks each against its real source, corrects the list's fields and penalties, and records a verdict. The list's weight is **not** recalculated by any of this: refresh the books primary ranking configuration by hand afterwards (admin **Refresh Rankings**). Every write tool says so in its description.

## The pieces

| Piece | Where |
|---|---|
| Queue and audit rows | `ListAudit` (`list_audits` table); services in `app/lib/services/lists/audits/` (`queue`, `start`, `finish`, `release`, `counts`, `snapshot`, `diff`) |
| REST and MCP tools | the admin OpenAPI document, `config/api/v1/admin_openapi.yaml` (controllers under `Api::V1::Admin::Books`) |
| Agent prompt | `config/mcp/books/prompts/list_audit.md.erb`, built by `Services::AgentPrompts.for_list_audit(list: nil\|list)` |
| Penalty rules for the agent | `penalties.guidance` column, loaded from `config/penalties/guidance.yml` |
| Admin pages | `/admin/list_audits` (queue page), the books admin list page, the lists index |

## Who voted (`lists.voter_details`)

Voter names, roles, how the panel was chosen and where the roster comes from are research that took effort to find, and used to live inside `description`, where audits dropped them while rewriting it as 2 to 4 reader sentences. They now have their own text column, `lists.voter_details` (max 20,000 characters, generic across domains). It is one of `Services::Lists::AdminUpdate::FIELDS` (right after `description`), so it is audited, shown by `get_admin_list` and editable through `update_admin_list` (string or null; null clears it). The admin list form (every domain) has a "Who voted" textarea. The public API's full list shape (`get_list`) carries it as `voter_details` (string or null). Only the books public list page renders it: a "Who voted" section under the description, plain text with line breaks kept, folded into a `<details>` when longer than 600 characters, and not in the meta description. The audit prompt tells the agent to put voter detail there, never drop names already recorded, move names out of a description into it, and treat a full roster's size as a confirmed `number_of_voters` and a partial roster's as a floor. The books list show page is edge-cached for 24 hours with no purge, so an edit can take up to about a day (plus the 1 hour stale-while-revalidate) to appear for anonymous visitors.

## The tools

All on the admin MCP endpoint (`POST /api/mcp/admin`, see `docs/features/mcp-server.md`). Reads need `books:admin:read`, writes `books:admin:write` plus the policy that lets the token's owner edit lists.

| Tool | Does |
|---|---|
| `search_admin_lists` | Books lists with status, item count, weight on the default primary configuration and latest finished audit. Filters `q`, `status`, `audit` (`not_audited`, `verified`, `unverifiable`, `in_progress`), `sort` (`weight`, `name`, `id`) |
| `get_admin_list` | One list with its editable fields, flags, attached penalties and audit state |
| `list_admin_list_items` | The list's items, to check against the source |
| `list_admin_penalties` | The books penalty catalogue with each penalty's `guidance` and, for a dynamic one, the list field that drives it |
| `update_admin_list` | Edit a subset of the list's fields and the nine flags; returns `changed` |
| `attach_list_penalty`, `detach_list_penalty` | Static penalties only. A dynamic penalty is a 422 naming the field to set instead |
| `start_list_audit` | Takes the next list (or the one in `list_id`) and returns the audit plus the list |
| `finish_list_audit` | Closes the audit with `verdict`, `note`, `sources`; returns the server-computed `changes` |
| `release_list_audit` | Gives the list back with no verdict |

Public side: `GET /api/v1/penalties` (`list_penalties`) lists the penalty catalogue, and the full `get_list` shape carries `penalties` (name, category, category title, description), the set the website's weight breakdown shows. Details in `docs/features/public-api.md`.

## Queue and audit rules

- **A list is audited once.** A finished audit (`verified` or `unverifiable`) removes the list from the queue for good. Auditing it again takes an explicit `list_id`.
- **Order.** Lists never started come first, by weight on the books default primary configuration (heaviest first), then id. Lists with an earlier audit that was released, or whose in-progress lease expired, come after them, oldest start first; weight only breaks ties there.
- **One open audit per list**, enforced by a partial unique index. The lease is 3 hours (`ListAudit::LEASE`) and `start_list_audit` renews it on resume. An expired lease frees the list for another admin.
- **A start with no id always claims a new list**, so two sessions on one admin account never share one. Resume is by id only: `start_list_audit` with the `list_id` of your own open audit renews its lease (`resumed: true`). A list held by someone else is a 409. Start, finish and release also need `Books::ListPolicy#update?` for the token's owner (403 otherwise).
- **Finish** needs a `verified`/`unverifiable` verdict, a non-blank `note` and `sources` (http(s) URLs; at least one for `verified`). A source on our own sites (thegreatestbooks.org, thegreatestmusic.org, thegreatest.games, any subdomain, or an archived copy of one) is refused with a 422: those pages repeat our own data, and a search for a list often puts them first. Through the API only the holder may finish or release (409 otherwise). The admin page's Release lets any books admin with write access release someone else's audit.
- **Snapshots.** `start` stores a `before` snapshot of the list's fields, flags and penalties; `finish` stores `after` and computes `field_changes` (returned as `changes`) from the two. The agent never reports its own diff.
- **Release** marks the audit `released`; the list goes behind lists never started.

## Penalty guidance

`penalties.guidance` is the rule an agent follows when deciding whether a penalty applies. `description` stays the short reader-facing blurb the website shows. Edit guidance on the admin penalties form.

`config/penalties/guidance.yml` holds the starting text keyed by penalty id with the expected name as a guard. `bin/rails penalties:load_guidance` fills blanks only by default, and prints five buckets: `filled`, `overwritten` (only with `OVERWRITE=1`, which replaces guidance whose text differs from the YAML; the name check still applies), `skipped_present`, `mismatched` (the row at that id has a different name) and `missing` (no such id). Check `mismatched` and `missing` are empty after a production run.

A dynamic penalty (its value comes from a list field) is never attached by hand. `Penalty::DRIVING_FIELDS` maps each `dynamic_type` to the list field that drives it (`Penalty#driving_field`; `percentage_western` is computed from the list's books and has none). `Penalty.books_catalogue` is the set the tools and the public endpoint expose: books and global penalties, not member-owned.

`creator_specific` has no books penalty row, so setting that flag costs nothing today.

### Geography penalties

Geographic scope is the `location_specific` flag (penalty 15, dynamic): it carries the base cost (20 on books configurations) and exempts the list from the western-canon penalty (23). Penalty 46, "only covers an area smaller than a country", is attached in addition when the place is a state, city or region (15, so a sub-national list costs 35). The per-place penalties (31, 36, 37, 38, 39, 42), "specific voter details are lacking" (21), "genre fiction, multiple genres" (27) and "half the voters are not experts" (32, merged into 44) were removed by `penalties:consolidate`.

`bin/rails penalties:consolidate` is a dry run that prints, per step, what it would do: lists flagged, attachments moved, penalties deleted with their list counts, values set per books configuration, penalties renamed. `APPLY=1` writes, in one transaction. It is idempotent and refuses the whole run if a known penalty id holds an unexpected name. Weights change at the next ranking refresh: geography values move, and removing #21 (40 on the books year rankings) raises the weight of the lists that carried it there. Every books configuration without a #15 value gets one (20), which has no effect until a location-specific list feeds it. A rename only happens while the penalty still has its old name, so later edits to the new text are kept.

## Rake tasks

| Task | Does |
|---|---|
| `bin/rails penalties:load_guidance` | Loads `guidance.yml` into blank `guidance` columns; `OVERWRITE=1` also replaces differing text |
| `bin/rails penalties:consolidate` | Folds the geography penalties into `location_specific` + 46, merges 32 into 44, deletes 21 and 27. Dry run; `APPLY=1` writes |
| `bin/rails penalties:detach_dynamic` | Lists hand-attached dynamic penalties on lists; a dry run. `APPLY=1` destroys those attachments. Dynamic penalties must come from the list's fields, not from an attachment |

## Admin pages

- `/admin/list_audits` (books host): counts (not audited, verified, unverifiable, in progress), the recent audits, **Copy prompt** (the prompt with no list: the agent starts the queue) and **Release** on an open audit, for a stuck lease.
- The books admin list page has **Copy audit prompt** (the prompt pinned to that list, with its current weight lines) and the list's audit history.
- The lists index has a "Last audit" column and an `audit` filter with the same four values as the tool.

## Gaps

- Weight is never recalculated by an audit; the refresh is manual.
- No automated re-audit schedule: a verified list stays verified until someone asks by id.

## Research rules the prompt enforces

Two rules came out of the first production audits (2026-11-22), where an agent marked list 122's voter count unknown because it could not open the archived source page, although that page names all 37 contributors:

- **A page that does not load is not evidence.** The agent never clears or downgrades a recorded fact because it could not reach or confirm the source; it keeps the fact, names the page in its note, and uses `unverifiable` if nothing else could be checked. The prompt also points the agent at `fetch_page` (the admin MCP tool that fetches a page through the page fetcher, see `docs/features/page-fetcher-service.md`) to try before giving up on a page.
- **Keep a recorded voter count unless a source contradicts it.** An unconfirmed count stays (the flag is left as it is; see the burden-of-proof section below). `voter_count_unknown` (which costs as much as a single voter) is for lists where no count was ever recorded and none can be estimated; a full roster gives a confirmed count; a partial roster is only a floor.

The guidance for penalties 13, 14 and 18 says the same: keep a recorded count; a stated count, or the number of voters the source names when it names them all, is confirmed; `voter_count_estimated` is only for a count the agent inferred (the source states no number and does not name every voter) or raised to a floor set by a partial roster. After a deploy that changes `guidance.yml`, run `bin/rails penalties:load_guidance OVERWRITE=1` in production.

- **`high_quality_source` is on hold.** The agent must not change it (prompt rule, 2026-11-22): the flag cuts a list's total penalty by a third, and the first audits set it liberally. How source quality should affect weight is being redesigned separately.

## Burden of proof and `items_need_revision` (2026-11-22)

Reviewing nine production audits showed the agent changing fields whenever it was uncertain and reading penalty rules generously. It marked list 44's voter count estimated because our order matched a newer online snapshot, although the source states 125 voters and names them all; it added penalty 3 to "1001 Books You Must Read Before You Die", which the rule says does not take it; it added penalty 6 to a list where translations qualified. The prompt now carries four rules:

- **Burden of proof.** A field changes only when a source directly contradicts it, or when it is blank and a source states the value. Uncertainty goes in the note, not in the field.
- **Record what the source states.** Field values follow the list's own source: its live website as it stands now. When the source publishes each edition on its own page and our list is one edition, that edition's page is the source. If the live page will not load, `fetch_page` first, then an archived copy (said so in the note); an archived or older edition is used only when no live page exists. The agent does not reason about which snapshot or edition our copy came from. If our books do not match the source, it sets `items_need_revision` and says what differs.
- **Penalties need a match, not a fit.** Add a penalty only when its guidance clearly applies; remove one only when its guidance clearly does not. The agent quotes, in the note, the source sentence that shows it and the guidance sentence it meets (for a removal, the guidance condition the list does not meet). This covers setting or clearing a field that drives a dynamic penalty (`location_specific`, `category_specific`, `creator_specific`, `num_years_covered`, the voter fields); for an estimated count, `voter_count_unknown` or `voter_names_unknown` it quotes the source sentence the judgement rests on, or says the source gives none; `yearly_award` (true for a recurring award or yearly list) also needs its source sentence. If it cannot give what the rule asks for, the penalty or field stays.
- **Full rosters.** When the source lists every voter, all of them go in `voter_details`.

Voter counts follow the same principle. A count the source states, or the number of voters it names when it names them all, is confirmed. `voter_count_estimated` is only for a count the agent inferred because the source states no number and does not name every voter, and only then does "count conservatively, lower-middle of a plausible range" apply. Keeping a recorded count the agent could not confirm leaves the flag as it is. When the source names only some voters and states no number, the number named is a floor: a blank count is filled, or a recorded count below it raised, to at least that number with `voter_count_estimated` true; a recorded count at or above it stays. The burden-of-proof rule covers factual fields, flags and counts; a blank `number_of_voters` may be filled by the voter-count rules, and `description` and `voter_details` follow their own rules.

**`lists.items_need_revision`** (boolean, default false, not null; admin only, not in the public API or on a public page) marks a list whose books do not match its source (a different edition or snapshot, missing or extra entries) and need redoing. It is one of `AdminUpdate::FIELDS` (after `voter_details`), so it is snapshotted, diffed, returned by `get_admin_list` and in every `search_admin_lists` row, which also takes `items_need_revision=true` as a filter.

- **Who sets it:** the agent through `update_admin_list` (true only), or an admin on the shared list form (checkbox "Items Need Revision").
- **Who clears it:** only an admin, by unticking the form checkbox. `Services::Lists::AdminUpdate` refuses `items_need_revision: false` with a 422 ("only an admin clears this flag in the admin UI") while the list has it true; false on a list that is already false is a no-op.
- **Where it shows:** an "Items need revision" badge by the title on the admin list page, and a "Needs item revision" checkbox on the books lists index (`items_need_revision=1`, combinable with the audit filter). The form checkbox and the filter are books only. A mismatch includes a different order, for ranked sources only. The source that wins is the list's live website as it stands now; an archived or older edition only when no live page exists (if the live page will not load, `fetch_page` first, then an archived copy with a note). When the source publishes each edition on its own page and our list is one edition (a yearly award, a decade-by-decade series), that edition's page is the source. A list flagged for revision can still be `verified`: the verdict covers fields and penalties.

Guidance changes (load with `penalties:load_guidance OVERWRITE=1`):

- **3** (not just best/favourite): lists of the books that mattered most to the voters, moved or affected them most, desert-island picks, and books everyone should read count as best or favourite and do not take it.
- **6** (one language): a requirement that an edition exists in a language, with translations allowed, is not a language limit.
- **15** (one location): a requirement about where a book was published or sold (for example "published in the US", translations allowed) is not a limit by place.
- **18** (estimated count): only when the agent derived the count; estimated only when the count is inferred (no stated number, not every voter named) or raised to a partial-roster floor; a stated count, or a full roster's size, is confirmed, and keeping an unconfirmed recorded count does not make it estimated.
