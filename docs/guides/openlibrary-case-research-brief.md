# Brief for a research model: matching our books to Open Library works

Paste everything between the rules below into a research model (ChatGPT with web
search, or equivalent) as its instructions, then paste one case per message.

Written because the first attempt failed in an instructive way: the model
researched the case well and answered a **different question** — it audited
whether our identifiers were correct, which is genuinely useful but is not what
a label decides. The fix is not better research. It is telling it the question.

What a research model adds that the local tooling cannot: it can reach Amazon to
check what an ASIN actually names, read Goodreads edition details, and find the
English or romanised title of a Japanese or Korean work. Those are exactly the
three things that have blocked cases here.

---

## What you are deciding

**Which single Open Library WORK is this book?**

A Book in our system is the *work*. Edition, printing, format, cover, publisher
and **language** are all irrelevant to identity. *The Adventures of Augie March*
and *As Aventuras de Augie March* are the same Book. A hardcover and a paperback
are the same Book. A 2005 reissue is the same Book.

## What you are NOT deciding

- **Whether our stored identifiers are correct.** If you notice a wrong ISBN or
  an ASIN that names a different book, put it under `NOTES` at the end — it is
  valuable and it goes on a separate repair track — but it does not change the
  answer. An identifier that is wrong is usually also absent from Open Library,
  so it never affects the match.
- Which edition is "best", or which record has the nicest metadata.
- Anything about how our database is structured.

## Answer format

```
VERDICT:   match | no_match | ambiguous
WORK_KEY:  OL#######W        (required for match; omit entirely for no_match)
RULE:      same_work | translation | revised_edition | omnibus_vs_parts |
           collection | adaptation | duplicate_work | wrong_data |
           not_in_open_library
CONFIDENCE: high | medium | low
RATIONALE: one or two sentences, naming the evidence that decided it
NOTES:     anything else you found (wrong identifiers, OL data errors)
```

`no_match` always takes `RULE: not_in_open_library` and never a work key.

The dossier you are given lists **every** candidate, not a sample, and prints
our subtitle when we hold one. The subtitle is sometimes the whole
identification: one row reads `The Story Of The Stone... Vol. 4` with subtitle
`The Debt of Tears`, and Open Library's work is `The Debt of Tears (... Volume
4)`.

## The decision procedure

**1. Start from the identifiers.** Which candidate works do our ISBNs, ASINs or
Goodreads ids reach? Those come first. If none of our identifiers reaches any
candidate, all candidates stay in play and you are working from title, author,
year and page count instead.

**2. Rule out the candidates that are different books.** This is the part that
needs judgement and it is why you are here. A shared title is not identity —
`title_fp_freq` in the case data tells you how many Open Library works share
that fingerprint; when it is in the hundreds or thousands, expect most
candidates to be unrelated books.

**3. Count what survives.**

- exactly one → `same_work`
- more than one → `duplicate_work`: Open Library holds this one book as several
  works. Pick the most consolidated record (see tiebreak) and say in the
  rationale how many duplicates there were.
- zero → search harder before concluding `no_match` (see the non-Latin trap).

**4. If our row and the chosen work are in different languages**, the rule is
`translation` rather than `same_work`. Still the same Book; the rule records
that the language differs.

## Tiebreak, when several survive — read the precedence carefully

This is the one rule that has been misread, so it is spelled out. It is a
**precedence**, not a list of equally weighted signals:

1. **Prefer works our identifiers reach and that something corroborates.** An
   ISBN of ours landing on a work outranks every curation signal.
2. **Apply the consolidation tiebreak WITHIN that group** — edition count, then
   reading-log, then revision, then how many identifier types the work carries.
3. **Only step outside that group** when the identifier-bearing record
   demonstrably combines different books. Say so explicitly when you do.

Edition count does not override our own ISBN. Two real cases show the line:

- *The Brain* — `OL20822331W` carries our ISBN with one edition, `OL19762848W`
  has two. **Our ISBN wins.** Consolidation is a tiebreak within the
  identifier-bearing group, not a way out of it.
- *Aristotle* — `OL19760957W` carries our ISBN but also contains the unrelated
  2011 collection *Aristotle: Metaphysics and Practical Philosophy*, so its
  editions are not all this book. `OL21511771W`, whose three Princeton editions
  all carry the right subtitle, is the better record. **This is the exception,
  and it needs the contamination stated in the rationale.**

## Traps that have actually cost us

**The work-level title is a summary; the edition list is the evidence.** This has
misled five times. A work titled `Collected Poems` whose editions are all 1953
New Directions printings is the American edition of `Collected Poems 1934-1952`.
Open Library truncates the work title of the 2012 Blackbook coin guide and
credits the work to the wrong Hudgeons, while its edition carries our exact
ISBN. Always read the editions.

**"Collected"/"Complete" vs "Selected".** A *Collected Poems* has one corpus, so
multiple Open Library works for it are usually real duplicates. A *Selected
Poems* is one editor's choice, and different editors chose differently — those
are usually different books. Page counts are the fastest tell: a 63-page
Grey Walls selection and a 421-page Heath selection are not the same book.

**An identifier is a claim, not a proof.** Pamela Anderson's *I Love You* carries
an ISBN that Open Library holds on *New Cookbook by Paul Anthony*. Never accept
an identifier match unless the author or the title also agrees. **A matching
year is not corroboration** — with one edition year it just means "published the
same year".

**A shared surname means the wrong person more often than the right one.** Paul
Auster against Sara Auster, Ann Coulter against Catherine Coulter, Mahatma
Gandhi against Rajmohan Gandhi. 10,607 books in our catalogue disagree with Open
Library this way. A dropped middle initial or a reversed name order (`Feng
Jicai` / `jicai feng`) IS the same person.

**Non-Latin titles: Open Library usually has the book under its English title.**
僕のヒーローアカデミア 2 is `My Hero Academia, Vol. 2`. 나 혼자만 레벨업 10 is
`Solo Leveling, Vol. 10`. Blocking cannot bridge the scripts, so the case will
show **zero candidates** and look like a `no_match` when the book is plainly
there. Always search the English and romanised titles before concluding absence.
Nineteen of fifty-seven such cases turned out to be present.

**A `no_match` only ever means "not found by the best search anyone ran."** Say
so, and say what you searched.

**Expect the candidate list to be incomplete, and say when the answer is not in
it.** Measured over 28 researched matches, **10 correct answers — 36% — were
never produced by blocking at all**; in the short-title stratum it was 8 of 10.
Blocking cannot fire on a title fingerprint shorter than four characters and
cannot bridge scripts, so for short, non-Latin or romanised titles the working
assumption should be that the right work is *absent from the candidates* and
has to be found by search. Naming a work key that was not on the list is not a
failure — those cases are the only measurement of candidate recall this project
has.

**Some of our rows are several books fused together.** Our merge process copies
the child's identifiers onto the parent, so a merged row's identifiers can
legitimately reach several genuinely different works — book #28542 `Selected
Poems` reaches James Agee, Paul Celan *and* Chaucer. When the identifiers reach
works that are clearly different books **and our row's title/author cannot
distinguish which one it is**, answer `ambiguous` and say the row looks like a
merge of N books. Do not pick one arbitrarily.

But distinguish that from a row that is **one** book carrying junk identifiers —
*The Right Side of History* by Ben Shapiro is one book, even though six of its
seven ASINs name other books. There the answer is clear; the junk goes in
`NOTES`.

## Saying "I can't tell" is a correct answer

A wrong match is far more expensive than a missing one. A wrong match fuses two
different books in our database and is painful to undo; a miss just means we
create a new record, which is the status quo. So:

- If two candidates are both defensible, answer `ambiguous` and explain the
  split. Do not pick one to seem decisive.
- If you cannot verify something, say which fact you could not establish.
- `CONFIDENCE: low` is useful information, not a failure.

## The NOTES field is worth as much as the verdict

Across 65 researched cases the notes have found three stored keys pointing at
entirely different books, a Goodreads id belonging to another author's novel,
several ISBNs naming stage adaptations, study guides and omnibuses, a missing
co-author, a subtitle borrowed from a different book, and a dozen wrong years.
Every one of those is a row that is wrong on a live site, and none of them
would have surfaced from the verdict alone. Write down anything that looks
wrong even when it does not change the answer.

## What we most need from your web access

1. **What an ASIN actually names.** Amazon is the only source; we cannot check.
2. **Goodreads edition details** — page count, publisher, publication date,
   original title. Page count has settled more of these cases than anything else.
3. **The English or romanised title** of a non-Latin work, and whether an
   official translation exists.
4. **Whether two similarly titled books are the same book** — especially
   anthologies, collected editions, omnibuses and series volumes.

## Worked example

```
OURS   #54759  'Selected Poems'
       authors: Algernon Charles Swinburne
       year: 1904
       goodreads=6392363
CANDIDATES (7, all author_title_fp, title_fp_freq=1981, our ids reach none)
 [1] OL25782157W  2017 Taylor & Francis (ed. L. M. Findlay)
 [2] OL17967711W  1939 Oxford U.P.  339pp
 ...
 [5] OL32056222W  1950 Macmillan    324pp
```

```
VERDICT:    match
WORK_KEY:   OL32056222W
RULE:       same_work
CONFIDENCE: high
RATIONALE:  Goodreads 6392363 is the 1950 Macmillan printing, 325pp; OL32056222W
            holds edition OL43782804M, 1950 Macmillan, 324pp -- a front-matter
            difference. The other six are different editors' selections sharing a
            generic title (63pp Grey Walls 1948, 421pp Heath 1905, 339pp Oxford
            1939), so after ruling them out exactly one remains.
NOTES:      Our stored year 1904 contradicts the 1950 publication. Neither the
            Goodreads id nor ASIN B0DLT8Z3WP is in Open Library.
```
