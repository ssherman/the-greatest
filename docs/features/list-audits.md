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

## The tools

All on the admin MCP endpoint (`POST /api/mcp/admin`, see `docs/features/mcp-server.md`). Reads need `books:admin:read`, writes `books:admin:write` plus the policy that lets the token's owner edit lists.

| Tool | Does |
|---|---|
| `search_admin_lists` | Books lists with status, item count, weight on the default primary configuration and latest finished audit. Filters `q`, `status`, `audit` (`not_audited`, `verified`, `unverifiable`, `in_progress`), `sort` (`weight`, `name`, `id`) |
| `get_admin_list` | One list with its editable fields, flags, attached penalties and audit state |
| `list_admin_list_items` | The list's items, to check against the source |
| `list_admin_penalties` | The books penalty catalogue with each penalty's `guidance` and, for a dynamic one, the list field that drives it |
| `update_admin_list` | Edit a subset of the list's fields and the eight flags; returns `changed` |
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
- **Finish** needs a `verified`/`unverifiable` verdict, a non-blank `note` and `sources` (http(s) URLs; at least one for `verified`). Through the API only the holder may finish or release (409 otherwise). The admin page's Release lets any books admin with write access release someone else's audit.
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
