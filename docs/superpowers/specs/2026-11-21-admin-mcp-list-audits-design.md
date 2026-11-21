# Admin MCP: list audits (metadata and penalties)

Status: draft for Shane's review, 2026-11-21.

## Why

Shane wants to hand a books list to Codex and say: "deep research this list, decide which penalties
belong on it and which don't, and correct any metadata that is wrong." Codex works over the admin
MCP server and edits directly. The aim is to make every books list as accurate as possible, because
a list's metadata and penalties set its weight, and the weights drive the ranking.

Today the admin MCP has about 65 tools and **none of them touch lists, list items or penalties**.
The public MCP reads lists but leaves out penalties, the editorial flags and the weight breakdown
(spec `2026-09-20-public-api-lists-and-rankings-design.md`, D10), even though the public list page
on the web already shows the weight breakdown.

Prior art: the music and games admin list pages have a "Research Prompt" modal
(`Admin::Lists::ResearchPromptModalComponent`, books excluded) that asks an AI the right research
questions, but a person then copies the answers into the form by hand. This design is that, done
end to end by the agent, for books.

## Goals

1. Codex can read everything we hold about a books list, research it, and then directly:
   - correct its metadata fields;
   - attach and detach static penalties;
   - correct the fields that drive the dynamic penalties.
2. Codex understands every penalty well enough to apply it consistently: each penalty carries an
   agent-facing "when to apply" rule next to its reader-facing description.
3. Each audit leaves a record: who ran it, Codex's note and sources, and a server-computed
   before/after of what changed. An audit that changes nothing is a confirmation, and is recorded
   as one.
4. Two ways in, one prompt:
   - a **Copy audit prompt** button on each books admin list page, with that list's data embedded
     ("please deep research this list: <all the metadata>");
   - an **audit queue** page that feeds Codex lists in order with the same rules.
5. The public MCP gains penalties, read-only.
6. Remove the one dynamic penalty attached by hand (see Data fixes).

## Non-goals

- **List items.** Adding, removing or relinking items is wanted later, as its own piece. This
  design only *reads* items (Codex needs them to judge years covered, western share, genre scope).
  The tools are shaped so item writes slot in as more tools later.
- **Weight refresh.** Shane refreshes weights by hand in admin, as today. No refresh tool or
  endpoint. Tool and prompt text must say that edits do not change the weight until a refresh.
- Music, games and movies lists. Books only (the MCP serves books only).
- Creating, editing or deleting penalties themselves through the API, or changing penalty values on
  ranking configurations.
- Proposals for review. Codex edits directly (Shane's decision).
- Deleting lists, or changing a list's `status` (see Decisions).

## Anti-goals

- An audit record that trusts Codex's own account of what it changed. The diff is computed by the
  server from snapshots.
- Rules for applying penalties that live only in a prompt and drift from the penalties they
  describe. The rule lives on the penalty.
- A hand-attachable dynamic penalty. The model already refuses one (`ListPenalty#penalty_must_be_static`);
  the API must go through the same validation, never around it.

## Approaches considered

- **A. Direct-edit tools plus a list audit record (chosen).** New admin tools read and edit lists
  and penalties directly; `start_list_audit` / `finish_list_audit` bracket a run and the server
  stores a before/after diff. Matches the series and duplicates flows. Items later = more tools.
- **B. A new enrichment-queue type (`books.list_audit`).** Reuses claim/lease, the queue page and
  the ledger, but it is propose-then-apply in disguise: Codex submits one answer holding every
  change and the server applies it. Codex cannot edit, re-read and adjust; every new editable thing
  widens the answer schema. Rejected because Shane chose direct edits.
- **C. Direct edits, with the enrichment queue only tracking which list is in progress.** Bends the
  queue's submit/apply contract into a no-op to reuse a page. Dropped.

## What exists (facts the builder needs)

- Books lists in dev (a production restore): 1,093 (758 active, 316 unapproved, 14 approved,
  5 rejected). 910 list-penalty attachments.
- Of the active/approved books lists: `num_years_covered` is null on 568, `number_of_voters` null on
  155, `location_specific` set on 137, `category_specific` on 165, `high_quality_source` on 49,
  `creator_specific` on 0. A null `num_years_covered` or `number_of_voters` means **no** penalty
  from that curve, not a missing value the curve punishes: null is right for an all-time list
  (most of the 568), and a list whose voter count is unknown should carry `voter_count_unknown`
  (141 of the 155 do). Values in use for years covered: 1 (yearly awards, 48 lists), 100, 10, 25.
  The books primary configuration's median voter count is 24.
- Penalties that apply to books lists: `Books::Penalty` and `Global::Penalty` rows with
  `user_id IS NULL` (36 in dev). 27 are static (attached by hand through `list_penalties`), 9 are
  dynamic (`dynamic_type` set; computed by `Rankings::WeightCalculatorV1` from list fields).
- Dynamic penalty → field that drives it:

  | dynamic_type | driven by |
  |---|---|
  | `number_of_voters` | `number_of_voters` (curve) |
  | `voter_names_unknown` | `voter_names_unknown` |
  | `voter_count_unknown` | `voter_count_unknown` |
  | `voter_count_estimated` | `voter_count_estimated` |
  | `category_specific` | `category_specific` |
  | `location_specific` | `location_specific` (also exempts the list from `percentage_western`) |
  | `num_years_covered` | `num_years_covered` (curve) |
  | `percentage_western` | the list's items' countries (books only); skipped when `location_specific` |
  | `creator_specific` | `creator_specific` (**no penalty row exists, so the flag does nothing on books**) |

- `high_quality_source` is not a penalty: it multiplies the list's total penalty by 2/3.
  `estimated_quality` does not enter the weight at all.
- A penalty's cost is its `PenaltyApplication.value` on a ranking configuration. On the books
  default primary configuration (id 8 in dev) several penalties have **no** application, so they
  cost nothing there: 15 (`location_specific`), 18 (`voter_count_estimated`) and 21 ("Voters:
  specific voter details are lacking", attached to 36 lists). The tools must show this rather than
  let Codex think it is changing the weight.
- Geographic scope is two things that are meant to stack: the `location_specific` flag (stated
  regional focus, exempts from western penalty) plus one static geographic penalty (city, state,
  small region, country, large region, continent) that carries the cost. 100 of the 104 lists with
  a static geographic penalty also have the flag.
- Weights live on `RankedList` (`weight`, `calculated_weight_details`) per (list, configuration).
  They change only when the configuration is refreshed.
- `List` guards: `AutoGeneratedListError` on destroying a generated list; `ListItem` refuses edits
  on generated lists. List field edits on generated lists are allowed in the admin UI.
- Admin list form fields (`Admin::ListsBaseController#permitted_params`): name, description, source,
  source_country_origin, url, year_published, number_of_voters, estimated_quality, status,
  high_quality_source, category_specific, location_specific, yearly_award, voter_count_estimated,
  voter_count_unknown, voter_names_unknown, creator_specific, num_years_covered, raw_content,
  simplified_content.
- Admin API conventions to follow: operations in `config/api/v1/admin_openapi.yaml` with an `x-mcp`
  block become tools (`Mcp::Catalog`); controllers under `Api::V1::Admin::Books::`; resources under
  `Api::V1::Admin::Books::`; scopes `books:admin:read` / `books:admin:write`; `Current.acting_user` /
  `acting_via`; Copy prompts rendered by `Services::AgentPrompts` from
  `config/mcp/books/prompts/*.md.erb`; field edits share `Api::V1::Admin::FieldUpdate`.

## Design

### 1. Penalty guidance

- New nullable text column `penalties.guidance`: the agent-facing rule. The existing `description`
  stays the reader-facing blurb on `/rankings`.
- Editable on the admin penalties form (`Admin::PenaltiesController` permits it).
- First drafts for all books-applicable penalties are written by the builder and **reviewed by
  Shane before they are loaded**. Each rule says: what makes the penalty apply, what does not, which
  penalty to prefer when two overlap (country vs continent vs region; "genre fiction (multiple
  genres)" vs the `category_specific` flag; "not critics" vs "half not critics" vs "public voted
  but experts curated"), and for a dynamic penalty which field to set instead.
- Loaded by an idempotent rake task that fills `guidance` only where it is blank, matched by id and
  checked against the name (skip and report on mismatch). Added to the books launch todo as a
  manual production step. Not a data migration.

### 2. Admin tools (books, `/api/mcp/admin`)

Reads need `books:admin:read`, writes `books:admin:write`. All take integer list ids.

| Tool | Does |
|---|---|
| `search_admin_lists` | Books lists by `q` (name/source/url), `status`, `audit` (`not_audited`, `verified`, `unverifiable`, `in_progress`), sort. Returns id, name, source, year, status, item count, weight on the default primary configuration, last audit date and verdict. |
| `get_admin_list` | Every field in the update set below, plus status, item count, `auto_generated`, whether raw content exists; attached penalties (id, name, static/dynamic, category, value on the default primary configuration or "none"); the weight and `calculated_weight_details` on the default primary configuration and when that was last computed; the last few audits (date, user, verdict, note). Not `raw_content`, `simplified_content`, `items_json`, `wizard_state`. |
| `list_admin_list_items` | Read-only, paged in list order: position, book id, title, authors, first published year, countries, and unlinked rows' text. Enough to judge years covered, western share and scope. |
| `list_admin_penalties` | The books-applicable catalogue: id, name, type (Books/Global), static or dynamic, `dynamic_type` and the field that drives it, category, reader description, `guidance`, value on the default primary configuration (or none), how many books lists carry it. |
| `update_admin_list` | PATCH: name, description, source, source_country_origin, url, year_published, number_of_voters, num_years_covered, yearly_award, high_quality_source, category_specific, location_specific, creator_specific, voter_count_estimated, voter_count_unknown, voter_names_unknown, estimated_quality. Omit a key to leave it; `null` clears a nullable field. Unknown keys 422, like the other field-edit tools. Not `status`. |
| `attach_list_penalty` | `list_id`, `penalty_id`. Goes through `ListPenalty` validation: a dynamic penalty or another domain's penalty is 422 with the reason (and, for dynamic, the field to set instead). Already attached is a no-op success. |
| `detach_list_penalty` | `list_id`, `penalty_id`. Not attached is a no-op success. |
| `start_list_audit` | With `list_id`: opens an audit on that list. Without: takes the next list from the queue (section 4). Returns the audit id and the `get_admin_list` payload. If the caller already holds an unexpired audit on that list, returns that audit (resume, lease renewed) instead of opening a second. Refuses a list whose unexpired audit another user holds (names who). |
| `finish_list_audit` | `audit_id`, `verdict` (`verified` = researched and the list now matches what the source supports; `unverifiable` = could not find enough to judge), `note` (required), `sources` (array of URLs, required for `verified`). Returns the computed diff. |
| `release_list_audit` | `audit_id`, optional `note`: gives the list back to the queue untouched (Codex gave up mid-run or was interrupted). |

Every write tool's description says the weight does not change until an admin refreshes the
ranking configuration.

### 3. Audit record

New table `list_audits`: `list_id`, `user_id` (who ran it), `status` (`in_progress`, `finished`, `released`), `verdict`
(`verified`, `unverifiable`, null until finished), `lease_expires_at`, `started_at`, `finished_at`,
`before` jsonb, `after` jsonb, `changes` jsonb, `note` text, `sources` jsonb.

- `before` is snapshotted at start, `after` at finish: every field in the update set plus the
  attached penalty ids and names. `changes` is the field-by-field difference plus penalties
  attached and detached. Changes made by anyone during the window land in it; that is acceptable.
- An expired lease (proposal: 3 hours, long enough for a deep-research run) frees the list for the
  queue; a later `finish` on an expired audit still succeeds if no newer audit has started on the
  list, otherwise it is refused.
- One in-progress audit per list (partial unique index).
- Edits made with the write tools outside an audit work as normal and are not recorded here.
- Audits are run only through the API. There is no hand audit in the admin UI, so no `via`
  column (my call; add one if a UI audit ever arrives). The admin list page does get a
  **Release** button on an in-progress audit, so a stuck lease can be cleared without waiting for
  it to expire.

### 4. The queue and the prompts

- **A list is audited once.** A list with a finished audit (`verified` or `unverifiable`) is
  marked audited and never served by the queue again (Shane's decision). Re-auditing is deliberate:
  by id, from the list page's Copy audit prompt. The queue is empty when every eligible list has a
  finished audit, and the queue prompt's loop stops there.
- Queue order for `start_list_audit` without an id: books lists with status `active` or
  `approved`, not auto-generated, with no finished audit and no unexpired in-progress audit;
  highest weight on the default primary configuration first (the lists that move the ranking
  most). Unapproved and rejected lists are reachable by id only.
- A released audit does not count as an audit, but the queue puts lists that have had an audit
  started and released behind every untouched list (ordered by when that audit started), so a list
  Codex just gave up on is not handed straight back (my call).
- The books admin lists index shows whether each list is audited (last verdict and date) and can
  filter on it.
- Admin page `/admin/books/list_audits`: counts (not yet audited, verified, unverifiable, in
  progress), a table of recent audits linking to the list, and a **Copy prompt** for the queue.
- Books admin list show page: a **Copy audit prompt** button with the list's data embedded, and an
  **Audits** section listing past audits with verdict, note, sources and the diff.
- One template, `config/mcp/books/prompts/list_audit.md.erb`, rendered two ways: queue (loop
  `start_list_audit` with no id until none is left) and single list (the list's metadata, attached
  penalties and weight breakdown inline; call `start_list_audit` with its id). It carries the
  research rules from the music/games research prompt (count contributors conservatively, say
  whether each fact is confirmed, estimated or unknown, judge source reputation), tells Codex to
  read `list_admin_penalties` and follow each penalty's guidance, explains the
  `high_quality_source` multiplier and the geographic stacking rule, says a penalty with no value
  on the main configuration costs nothing, and says what a good description is. Codex is
  authorised to act without asking.

### 5. Public MCP (read-only)

- `get_list` (full trait) gains `penalties`: the penalties in effect on the list, each with name,
  category, category title and reader description. No values, no guidance, no flags. "In effect"
  means the same set the web list page's weight breakdown shows, so the API and the page agree.
- New `list_penalties` public tool and `GET /api/v1/penalties`: the books-applicable catalogue with
  name, category, category title and reader description, for explaining why a list weighs what it
  does.
- Additive only, per the public contract. The public-surface pin tests (tool counts, OpenAPI path
  lists, developers page) need bumping.

### 6. Data fixes

- Delete the one `ListPenalty` linking a dynamic penalty ("Voters: Unknown Names") to a
  `Music::Albums::List`. It is the only one in any domain. Done with the guidance rake task's
  companion or by hand in admin; the builder picks, and records it in the launch todo if it needs a
  production step.

## Decisions (mine, for Shane to check)

1. `status` is not editable through the API. Activating or rejecting a list moves the ranking far
   more than a field correction, so it stays a human click. Codex can recommend it in its note.
2. `raw_content` / `simplified_content` are left out of reads and writes (up to 1.5 MB, and the
   wizard owns them).
3. Penalty guidance is a column, not prompt text, so it is editable in admin and cannot drift from
   the penalty.
4. Unapproved lists are not in the queue; they are reachable by id. An `unverifiable` verdict counts as audited, so those lists are not re-served either.
5. Auto-generated lists are not in the queue but can be audited by id.
6. Lease of 3 hours.
7. `start_list_audit` resumes the caller's own open audit rather than refusing it.
8. A released list goes behind every untouched list in the queue.
9. No admin-UI audit and no `via` column; the list page gets a Release button for a stuck audit.

## Left to the builder

- Exact resource shapes and key order, OpenAPI wording, error codes beyond those named.
- Whether `search_admin_lists` paging/sort options mirror `list_admin_series`.
- The admin page layouts (follow the enrichment queue and series pages).
- How the per-list Copy prompt is rendered (component vs `Services::AgentPrompts` extension).
- Tests: model, service, request and contract tests per the existing admin MCP pattern; a
  Playwright E2E for the queue page's and the list page's Copy prompt buttons.
- Docs: extend `docs/features/mcp-server.md` and `docs/features/rankings.md`; launch-todo entry for
  the guidance rake task.
