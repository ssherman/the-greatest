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
labels      204   researched  142   proposed  75    = 421 decided
remaining    29   in /home/shane/ol-data/eval/needs-you.md

remaining by stratum:
  shared_key_collision 17 · stale_ol_key 12
```

`researched.jsonl`: 115 match, 21 no_match, 6 ambiguous.

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

The labels are the least valuable output. Across 142 researched cases:

- **26 candidate-recall failures** — the right work was never produced by
  blocking. 9 of them in `non_latin_title` (every manga and manhwa volume
  found so far was under its English title), 8 in `degenerate_title`. These are
  the only cases that measure recall; without them recall is 100% by
  construction. `EvalCase.found_outside_blocking` finds them.
- **37 wrong stored OL keys**, including Harari's *Nexus* keyed to a book about
  bees, a Mike Omer thriller keyed to a Batman parody, Rilke's *Sonnets to
  Orpheus* keyed to the *Duino Elegies*, Nagano's 1978 photobook keyed to a
  2019 novel by a different Nagano, and T. C. Boyle's *Stories* keyed to *The
  Adventures of Sherlock Holmes*. Twenty-five of the thirty-seven came from the
  first thirty-five `shared_key_collision` cases — the stratum is defined by the
  defect. Ten of those point at a *container* (an omnibus, a boxed set, a
  collected-works volume, the whole novel for a volume-I row) rather than an
  unrelated book, and two more at a grab-bag record that holds the book among
  unrelated ones. Four stored keys in the stratum were correct.
- **101 rationales carrying LOCALDATA findings** — wrong authors (Fritz Stern for
  Jessica Stern; Doyle Brunson for Russell Brunson), missing co-authors, wrong
  years, ASINs sitting in the `isbn10` column, ISBNs naming study guides, stage
  adaptations and sequels.

That stream of defects is the reason to keep going. Protect the `NOTES` section
of each answer, not the verdict.

## Open items, deliberately not done

- **The 75 proposals are unreviewed.** They were generated by rule, not
  researched. `/home/shane/ol-data/eval/proposals-to-check.md` is a stale
  rendering of an older set — regenerate it before using it.
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
