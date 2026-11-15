# Admin MCP: create author, enrich on first book, pen-name rules — design

Status: approved 2026-11-15. Short design.

## Intent

An admin agent working the duplicate queue needs to fix author records the way the rules below
describe, and one case needs a record that does not exist yet: two different people with the same
name, where only one has a record. The agent must be able to create the other person's author and
move the wrong books to it. Shane also wants every hand-created author enriched, which the admin
"New author" page has never done.

## Goals

1. **`create_author`** — `POST /api/v1/admin/authors`, operationId `createAdminAuthor`, scope
   `books:admin:write`, plus `Books::AuthorPolicy#create?`. Body (raw JSON, as `update_author`):
   `name` (required string), optional `alternate_names` (array of strings), `birth_year`,
   `death_year` (integers −3000..3000), `wikidata_qid` (string `Q` + digits).
   - A `wikidata_qid` already held by another author is refused with **409**, naming the holder
     (`id` and `name`). An unknown key is 422; a wrong type or a missing/blank name is 400/422 as in
     `update_author`'s split.
   - A given QID is stored the way an admin-added author identifier is (`source: :admin`,
     authoritative), so the enrichment starts from that person and never searches by name. Adding
     it starts the enrichment immediately (that is what an admin-added Wikidata id already does).
   - Responds 201 with the author in `get_admin_author`'s shape.
   - The admin "New author" page and the API share one create service.
2. **Enrich an author when it gets its first book.** When `Services::Books::BookAuthors::Edit.add`
   (behind the admin page and `add_book_author`) links an author that has never had an
   `AuthorEnrichment` workflow run, it starts one after the link commits. This gives a hand-made
   author the importer's ordering: the book importer already starts a created author's run only
   after the book and its author links are saved (`Workflows::Books::BookEnrichment.start`), so the
   Wikidata step sees the author's works. An author with no books is not enriched, as the importer
   already accepts.
3. **`reject_repair_verdict` refuses re-import matches.** A `reimport_match` verdict cannot be
   rejected (it would strand the readers); the API answers 422 pointing at `correct_repair_verdict`,
   and the admin repair-verdicts page hides or refuses its Reject for that kind with the same rule
   (shared `Review.reject`).
4. **Rules in the duplicates Copy prompt** (`config/mcp/books/prompts/duplicates.md.erb`), for
   author pairs:
   - Pen name of one person: merge into the person's record, named for the name they are best
     known by. Keep the pen name in `alternate_names`. Set `credited_as` to the pen name on every
     book printed under it (`update_book_author`).
   - Shared pen name (several writers): never merge; dismiss with note "shared pseudonym".
   - Same name, different people: never merge. If the other person has no record, `create_author`
     (pass their `wikidata_qid` when known), then on each wrong book add the right author, remove
     the wrong one, and remove any alternate name that belongs to the other person. After the books
     are linked, check the new author's match decisions; if the enrichment linked the namesake,
     `reject_match_decision_link`.
   - Identifiers: delete only `source: legacy` identifiers proven to belong to a different work;
     flag any other source in the note.
   - Write the evidence (the sources checked) in every note.

## Already in place (checked)

- Re-import verdict tools: list, get, approve and correct (`correct_repair_verdict` →
  `GoodreadsReimport::CorrectMatch` with `book_id` or `create: true`), PR #502.
- `update_author` changes `name` and `alternate_names` (#500); `update_book_author` sets
  `credited_as` (#503).

## Non-goals

- Cross-author QID refusal on `add_author_identifier` (only `create_author` gets it).
- Enriching authors that have no books.
- Bulk author creation.

## Approaches considered

1. **Enrich on first book link (chosen).** Covers every hand-made author (page, API) and always
   runs with at least one book linked.
2. **`create_author` takes `book_ids` and enriches after linking.** Mirrors the importer exactly but
   needs every book known up front and leaves the admin page unsolved.
3. **Enrich at create.** Runs with no works to corroborate; the VIAF step can match a better-known
   namesake.

## Left to the builder

Service names, how "never had a run" is checked (any `WorkflowRun` for the author with the
author-enrichment definition), the 409 problem type, tests, OpenAPI, pins (58 → 59), docs
(`mcp-server.md`, `admin_usage.md`).
