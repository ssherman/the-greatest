# Processing a research batch (operator notes)

Companion to `openlibrary-case-research-brief.md`, which is what the *research
model* gets. This is the other side: what to do when Shane pastes a batch of its
answers back. Written so the loop survives a context compaction.

**Working directory is `data-sources/`** inside the worktree
`/home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source`.

## The loop

Shane runs a batch through a web-search model (currently ChatGPT "Astra Extra
High"), pastes the answers here, and expects three things: the claims checked
against the artifact, the answers written down, and the dossier refreshed.

**1. Verify before recording.** Never take an answer on trust — it has been
wrong twice and both times the artifact caught it. What to check:

- every edition count it states
- every named edition (`OL…M`) actually carries the identifier it claims
- the side-claims: "the stored key is X", "the rival has N editions",
  "that other work is a different book"
- **when it picks a work with fewer editions than a rival**, confirm no
  identifier of ours reaches the rival. That is the precedence rule, and it is
  the thing it got wrong before the brief was rewritten.

A worked query lives in the git history — see the verification scripts in the
commits around `ec422ca5` and `9cb9e6be`. The shape is: read `works`,
`editions`, `identifiers`, `work_authors`/`author_names` and `popularity` from
`ArtifactPaths(root=Path("/home/shane/ol-data"), dump_date="2026-07-31")`.

**2. Record into `researched.jsonl`, never `labels.jsonl`.**

```
src/openlibrary/eval/cases/labels.jsonl      Shane's own, labeled_by="human"
src/openlibrary/eval/cases/researched.jsonl  machine-researched, human-accepted,
                                             labeled_by="agent_confirmed"
src/openlibrary/eval/cases/proposed.jsonl    machine proposals, UNREVIEWED,
                                             labeled_by="agent"
```

Build each row as an `EvalCase` so it validates on construction, copying
`stratum`, `book` and `candidates_shown` from the pool entry. Put everything the
research found into the rationale — the `LOCALDATA` notes are worth more than
the verdict (see below).

**3. Regenerate the dossier.** `--done` is repeatable and must list every file
holding answers, or finished work gets handed back:

```bash
uv run python -m openlibrary.eval.triage \
  --pool /home/shane/ol-data/eval/pool.jsonl \
  --labels src/openlibrary/eval/cases/labels.jsonl \
  --done src/openlibrary/eval/cases/researched.jsonl \
  --proposed src/openlibrary/eval/cases/proposed.jsonl \
  --report /home/shane/ol-data/eval/needs-you.md --dump-date 2026-07-31
```

Passing `--proposed` the real path **regenerates** the proposals. To leave them
alone, point it at a throwaway and pass `--done .../proposed.jsonl` instead.

**4. Then** `uv run pytest -q`, `uv run ruff check .`, `uv run ruff format
--check .`, and commit. CI runs the formatter as a step separate from the
linter; running only `ruff check` has broken the build once.

## State as of 2026-09-12

```
labels      204   researched  244   proposed   2    = 450 decided
remaining     0   -- /home/shane/ol-data/eval/needs-you.md is empty
```

`researched.jsonl`: 212 match, 22 no_match, 10 ambiguous, all `agent_confirmed`.
**The research loop is finished**, and the proposals have been reviewed: 73 of
the 75 were verified against the artifact on 2026-09-12 (every key re-derived,
21 rule fields corrected — 19 to `duplicate_work`, 2 to `translation`), accepted
by Shane, and moved into `researched.jsonl`. Their rationales begin "Proposed by
the identifier rule" so they can be told apart from the hand-researched rows.
The review itself is `/home/shane/ol-data/eval/proposals-review.md`.

**Two proposals are held back in `proposed.jsonl`** because the key may be wrong
in scope and only the web can say: `pseudonym_or_alt_name-005` (One Piece 60 —
our ISBN sits on a 2012 Viz edition titled only for the arc, "Paramount War",
while Viz's volume 60 proper carries a different ISBN) and `author_less_work-006`
(*1001 Arabian Nights*, year −800 — a corpus-titled row whose only ISBN is a
158pp three-tale chapbook; the -018 *Nights* shape). The triage tool re-proposes
both, so they will never appear in `needs-you.md`; hand them to the research
model from the review report.

Researched cases by stratum: shared_key_collision 80 · high_frequency_title 40
· stale_ol_key 30 · pseudonym_or_alt_name 29 · non_latin_title 26 ·
degenerate_title 20 · author_less_work 19.

**`stale_ol_key` keys are stale because Open Library merged the works — and the
redirect lands on the right one.** All 30 stored keys in the stratum are absent
from the 2026-07-31 works table; 28 redirect to the work the label chose, 2 to a
different record. The pool builder resolves redirects when it generates
candidates and tags the *target* `existing_key`, which is why the dossier showed
those keys with edition counts — an earlier version of this note read that as
"not stale" and was wrong. Following the redirect is the fix for this stratum.

**The exception moves you to a clean record our identifiers also reach — never
to a thinner record nothing of ours reaches.** Two `stale_ol_key` answers
stepped off a canonical record because of a minority of stray editions:
Gandhi's autobiography (140 editions, five identifier hits, eight misfiled
*Selected Writings*/*Lifelines* editions) to a one-edition print-on-demand
record, and *How to Measure Anything* (18 editions, four identifier hits, three
companion-workbook editions) to a one-edition Chinese translation. Both were
recorded on the canonical record. Eight in 140 and a companion workbook are
blemishes (King John, Rebecca, Adichie's guided journal); the exception is for
records that *are* two books (Colette's, Barthelme's, X-Factor's), and every
time it has fired so far the clean record also carried an identifier of ours.


**The brief's Pamela Anderson example is wrong, and so is the docstring built on
it.** `shared_key_collision-075`: ISBN 9780316573481 sits on `OL38014589W`
'New Cookbook by Paul Anthony' — but that record's three 2024 Little Brown
ISBNs are all Anderson's *I Love You: Recipes from the Heart*, and the same
placeholder author `OL352405A` holds an "I LOVE YOU — Carton of 10 Signed
Copies" record. It is her book with stale publisher-feed metadata, not a Paul
Anthony cookbook. The brief cites it under "an identifier is a claim, not a
proof", and `triage.py`'s `corroborated()` docstring cites it as the false merge
that justified dropping the year limb. The *principle* may still be right; the
*example* is a true match. Neither the brief nor the code has been changed —
that is Shane's call — but do not repeat the example.

**Re-runs can beat a recorded label.** `pseudonym_or_alt_name-004` was recorded
on an English duplicate; a re-run surfaced the Chinese original `OL11977540W`
(4 editions, under a fourth Rou Shi author key the earlier search missed) and
the row was amended in place to that key with `translation`. When Shane
re-pastes an already-recorded case, diff it against the file rather than
refusing it — the new answer may carry a record nobody had seen.

**Identifier-first applied to a public-domain classic.** Wharton's *Tales of
Men and Ghosts* (-049): our one ISBN sits on a 2012 CreateSpace record whose
author is misspelt "Edith Warton"; the 38-edition canonical record carries
nothing of ours. The brief's precedence (*The Brain*; Blue Period 6) gives the
CreateSpace record, and that is what was recorded. If the desired outcome for
classics is the canonical record when the ISBN-bearing one is print-on-demand,
that is a rule change for the brief, and this label flips with it.

**An expanded edition does not fire the exception.** The research model stepped
outside the identifier-bearing Dark Phoenix Saga record because its other
edition was Panini's 440pp French edition with tie-in material. That is the
saga in an expanded edition under the saga's own title — the same Book — not a
record that *is* two books. The exception needs a whole separate work merged in
(Colette's record holding White's *The Stories* and a Franklin Library novella
volume; X-Factor's holding volumes 7 and 11), not a fatter edition.

**A row titled as a canonical corpus matches the corpus record, when one
exists.** Martial's *Epigrams* (#8974) carries ISBNs for eight different
selections and Loeb volumes; the research model answered `ambiguous`. But OL
holds the corpus as `OL2241482W` *Epigrammata* (155 editions) and files
selections under it, so the row has a work-level answer. *One Thousand and One
Nights* (-018) stays `ambiguous` because OL has no corpus-level record there —
every candidate is one translation, selection or volume.

**Check the research model's tiebreak counts against the dump.** Its identifier
type count for Fortunata y Jacinta I used LibraryThing ids from the live site,
which the artifact does not hold, and missed an OCLC on the rival; in the dump
the two records tie. Its fifth Dark Phoenix record, `OL45881233W`, is not in
the 2026-07-31 dump at all.

**A collection edition titled after its lead work belongs to that work.** Row
#39492 `Тіні забутих предків` carries an ISBN naming a 352pp collection; the
research model answered `omnibus_vs_parts`. Open Library files the same shape
(a 1988 `povist ta opovidannya` edition) under the novella's work, and the
row's title is the novella's, so it was recorded `duplicate_work` on the
novella. `omnibus_vs_parts` is for rows whose *title* states the scope
difference (Bastard volume 3 against a set record; an omnibus row against a
single volume) — not for an edition that happens to bundle extra material.

Two local rows can settle on one OL work: #39906 and #38913 are both
Bulychev's `Путешествие Алисы` (the second under its alternate title). That is
a local duplicate pair, worth more than either label.

**R20b is binding on the rows it names.** `shared_key_collision-006` is book
#28542, which R20b (and `schema.py`, and the brief) cite as the merged-row
example. The research model labelled it a match on the grounds that the author
field says Agee; that is exactly the shape-(b) reading R20b rejected for this
row, so it is recorded `ambiguous` with the whole argument in the rationale and
a one-field flip described. Check the ruling before recording a match on a row
the ruling names.

**Holding a case back works.** `pseudonym_or_alt_name-012` was answered
`no_match`; the artifact held three `DUDEN.Das Woerterbuch der Synonyme` works
the research never saw. It was left in the dossier with the keys named, Shane
re-ran it, and the research model reversed itself with the Hueber-to-Duden
edition link the artifact could not supply. Do that rather than record a
`no_match` the artifact contradicts, and rather than guess the web fact.

When the dossier is regenerated with `--proposed` pointed at a throwaway, its
header reads "0 proposed automatically" and names the throwaway path. That is
cosmetic: the 75 proposals still exist and are still excluded from the list.

## What this has actually produced

The labels are the least valuable output. Across 244 researched cases (171 hand-researched, 73 promoted proposals):

- **28 candidate-recall failures** — the right work was never produced by
  blocking. 9 of them in `non_latin_title` (every manga and manhwa volume
  found so far was under its English title), 8 in `degenerate_title`. These are
  the only cases that measure recall; without them recall is 100% by
  construction. `EvalCase.found_outside_blocking` finds them.
- **47 wrong stored OL keys**, including Harari's *Nexus* keyed to a book about
  bees, a Mike Omer thriller keyed to a Batman parody, Rilke's *Sonnets to
  Orpheus* keyed to the *Duino Elegies*, Nagano's 1978 photobook keyed to a
  2019 novel by a different Nagano, and T. C. Boyle's *Stories* keyed to *The
  Adventures of Sherlock Holmes*. Thirty-four of the forty-six came from the
  fifty-two `shared_key_collision` cases — the stratum is defined by the
  defect. Twelve of those point at a *container* (an omnibus, a boxed set, a
  collected-works volume, an anthology for a single issue, the whole novel for
  a volume-I row) rather than an unrelated book, and four more at a grab-bag
  record that holds the book among unrelated ones. Nine stored keys in the
  stratum were correct, and one (Wharton) was a duplicate of the same book
  rather than wrong.
- **131 rationales carrying LOCALDATA findings** — wrong authors (Fritz Stern for
  Jessica Stern; Doyle Brunson for Russell Brunson), missing co-authors, wrong
  years, ASINs sitting in the `isbn10` column, ISBNs naming study guides, stage
  adaptations and sequels.

That stream of defects is the reason to keep going. Protect the `NOTES` section
of each answer, not the verdict.

## Open items, deliberately not done

- **Two held-back proposals** need a web check (see the state block).
  `/home/shane/ol-data/eval/proposals-to-check.md` is a stale rendering of an
  older set and can be deleted; `proposals-review.md` supersedes it.
- **`docs/data-quality/books-identifier-pollution.md` was never written.** The
  measurements exist: 24,885 books (15.8%) have identifiers reaching several OL
  works, 8,765 of those reach works sharing one title (OL duplicates) and 16,120
  (10.2%) reach works with *different* titles — an upper bound that mixes
  translations, bind-ups and real pollution. The refined count (identifiers
  landing on third-party study guides) was killed by a reboot and never re-run.
- **The initial-expansion measurement was never completed.** `Jerome K. Jerome`
  against `Jerome Klapka Jérôme` classifies as `surname_collision` because
  `classify_disagreement` does not expand an initial into a given name. That is
  demonstrated, but how much it inflates the 10,607-book `surname_collision`
  figure is unmeasured — and the author-repair plan rests on that figure. A job
  left in the background produced nothing for 24 hours because the waiter loop's
  `pgrep -f "initials.py"` matched *itself*; do not repeat that pattern.

## Rulings that are not in this file

`R20` and `R20b` in
`.superpowers/sdd/2026-09-01-open-library-data-service/progress.md` — why the
450-case quota was abandoned, and the difference between a merged row (several
books fused, no single right answer, skip it) and a polluted row (one book plus
identifiers belonging to others, label it normally). That file is **gitignored**,
so it exists only in this worktree; the load-bearing part is duplicated in
`schema.py` next to `MIN_CASES`.
