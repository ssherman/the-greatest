# Source rows and an agent prompt for proposed row moves

A short design: a small change.

## Why

An admin agent asked to review the 47 proposed `reimport_row` verdicts could not do it. The copied prompt for the
repair-verdicts page covers only `reimport_match`, so the agent listed matches, found none, and stopped. When it
was pointed at the row verdicts, `get_repair_verdict` returned an empty `source_rows`. Without the Goodreads CSV
row's title and author, there is nothing to judge a move by. For example, verdict 727764 would move user 71245's
row 1644:4 from *Sustainable Energy* (MacKay, #14031) to *The Wager* (Grann, #44971), and nothing in the response
says which book the reader actually listed.

A row is proposed, rather than approved automatically, only when the move would take an entry off a trusted book
(`DecideRow#settle`, `Cohort.trusted?`). The usual cause is that the old site's importer guessed the trusted book
and stamped this edition's Goodreads id onto it. The risk is a reader who really does have the trusted book.

## Goals

- `source_rows` on the API, MCP and admin verdict page shows the CSV row for `reimport_row` verdicts, and for
  `reimport_mixed` verdicts, which have the same gap (`payload["row_keys"]`).
- The admin page copies a row-move prompt when it is filtered to `kind=reimport_row`, and that prompt carries the
  review rule.
- `docs/features/goodreads-reimport.md` gains a "Reviewing proposed row moves" section with the same rule.

## Non-goals

- A correct action for row moves. `correct_repair_verdict` stays `reimport_match`-only by design. A row move is
  approved (the entry moves from the from-book to the to-book) or rejected (the move never happens and the reader
  stays where they are, which is the right outcome for a wrong move).
- `reimport_guess`. A guess exists because no CSV row explains the reader's entry (`DecideGuesses#unexplained_items`),
  so an empty `source_rows` is correct for it.
- Changing the API response shape.

## The review rule (prompt and doc say the same)

- Approve when the CSV row's title and author name the to-book and clearly not the from-book.
- Reject when the CSV row actually is the from-book, or when it is unclear.
- Rejecting a wrong move leaves the reader where they are; unlike a match, a rejected row move is the safe answer.
- Correction found in final review: "a move (not a copy) means no other CSV row of that reader lands on the
  from-book" does not hold. `DecideRow` decides move versus copy from the rows legacy put on the from-book only, so
  a row of the same reader heading to the from-book from elsewhere is not counted. The prompt and doc do not claim it.

## Approaches

- **A. A separate row-move prompt (picked).** A new `row_moves` agent-prompt queue, used when the page is filtered
  to `kind=reimport_row`. This is the same pattern `reimport_author` already uses with `author_verdicts`. Each
  prompt is about one decision, so the match prompt's "never call reject_repair_verdict" and the row rule's
  "reject when unclear" never sit in the same prompt.
- **B. One prompt for both kinds.** The default prompt would cover matches and row moves together. Rejected: one
  prompt would carry two opposite rules about reject, kept apart only by which kind each section applies to.

Shane picked A.

## Design

- **`Services::Books::RepairVerdicts::SourceRows`** resolves row keys by verdict kind:
  - Verdicts with `payload["rows"]` work as today: pairs of the old site's import id and a row number.
  - `reimport_row`: one key, `[payload["import_id"], payload["row_number"]]`, where the import id is our
    `books_goodreads_imports.id`.
  - `reimport_mixed`: `payload["row_keys"]`, pairs of our import id and a row number.
  - `pairs` (used for `source_row_count`) and `call` (rows with import and edition loaded, `limit` respected)
    both go through this. A key that names no row is dropped, as now. The query count stays fixed.
- **API.** `RepairVerdictDetailResource#source_rows` keeps its fields. `import_id` stays the old site's import id.
  The OpenAPI description for `source_rows` says so, and says that a re-import verdict's `payload.import_id` is
  our own import id, so the two numbers differ. `books` already includes the from-book and the to-book
  (`RepairVerdict#book_ids`); a test pins it.
- **Admin page.** The show page already renders `@source_rows` from `SourceRows.call`, so it picks the rows up
  with no view change.
- **Prompt.** `config/mcp/books/prompts/row_moves.md.erb`, with `row_moves` added to `AgentPrompts::QUEUES`. Its
  count is the current proposed `reimport_row` verdicts. The controller picks it when `params[:kind] ==
  "reimport_row"`. The prompt tells the agent to list with `kind=reimport_row`, read each verdict with
  `get_repair_verdict`, compare `source_rows` with `books`, approve or reject by the rule above, use
  `bulk_approve_repair_verdicts` only for verdicts it has read, act without asking, skip when it genuinely cannot
  tell, and report each verdict's id, action and one line of reasoning.
- **Docs.** The "Reviewing proposed row moves" section in `docs/features/goodreads-reimport.md`. The repair-verdicts
  entry in `docs/features/mcp-server.md` is updated if it describes `source_rows`.

## Tests

- A request test: a `reimport_row` verdict's `source_rows` is populated (title and author from `row.raw`, ISBN-13
  and Goodreads id from the edition, `import_id` the old site's id), `source_row_count` is 1, and `books` holds
  both the from-book and the to-book.
- `SourceRows` covers a `reimport_mixed` verdict and a key naming no row.
- The admin controller test: filtering to `reimport_row` assigns the row-move prompt.
- `AgentPrompts` test: the row-move prompt renders and its count tracks proposed `reimport_row` verdicts.

## Left to the builder

The prompt's exact wording, within the rule above. Whether the admin show page needs a system test or E2E: it is
an existing page with no new markup, so I'd say no.
