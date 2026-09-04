# Books: title strings the matcher cannot see past

**Measured 2026-09-04** against the `2026-07-31` Open Library artifact and a
development database refreshed from production (157,805 exported books).

```bash
cd data-sources
uv run python -m openlibrary.audit.titles \
  --root /home/shane/ol-data --dump-date 2026-07-31 \
  --books /home/shane/ol-data/eval/books.jsonl \
  --out ../docs/data-quality/books-title-gains-<date>.jsonl
gzip ../docs/data-quality/books-title-gains-<date>.jsonl
```

Read-only, ~2 minutes, touches nothing but the output file.
`books-title-gains-2026-09-04.jsonl.gz` is the 2,432 books that gain a
candidate, one JSON object per line with the stripped fingerprint and how
many OL works it reaches.

## The problem

The pipeline already fingerprints three ways — `title_fp`, `title_fp_nosub`,
`title_fp_noart` — and `author_title_fp` tries all nine combinations of them.
None of that helps when the noise is *inside* the title string, because `nosub`
strips the separate `subtitle` column and nothing else.

Somewhere between the source and our row, the parts got concatenated.
Book #143219 is stored as

```
Andrew Jackson And The Course Of The American Empire, 1767 1821 Volume I
```

while Open Library holds `Andrew Jackson and the Course of the American Empire`
(`OL273027W`). Remove the glued-on date range and volume number and the
fingerprints are identical. That one difference is the entire reason all four
blocking rules produced nothing for a book Open Library has **three** copies of.

## What is in the catalogue

| Shape | Books | Share |
|---|---:|---:|
| title contains its own `subtitle` column verbatim | 2,760 | 1.75% |
| title ends in a volume designator (`Volume I`, `Vol. 4`) | 4,829 | 3.06% |
| title carries a four-digit date range | 602 | 0.38% |
| **fingerprint changes when both are stripped** | **5,427** | **3.44%** |

Only the first is a **data defect** — the row holds the same words twice, and
`title_fp_nosub`, whose entire job is to compare without the subtitle, silently
does nothing on those 2,760 books. A volume number is not wrong; it is simply
absent from the string OL indexes, so it is a *matcher* problem.

## What the normalisation buys, and what it costs

`strip_matching_noise` removes a trailing volume designator and any four-digit
date range. Of the 5,427 books whose fingerprint changes, **2,432 reach no Open
Library work by `title_fp` today and gain at least one.**

| Candidates gained | Books |
|---|---:|
| 1 | 331 |
| 2–5 | 577 |
| 6–50 (under `MAX_TITLE_FP_FREQ`) | 1,110 |
| >50 — still suppressed by the cap | 414 |

So 2,018 usable. **That number should not be read as a win**, because of how it
splits:

| Cause | Books gained | Usable |
|---|---:|---:|
| the volume strip | 2,360 | 1,976 |
| the date-range strip | 72 | 42 |

**97% of the gain comes from the volume strip, and almost all of it pairs a
single volume with the series as a whole.** `Spice & Wolf, Vol. 04` gains
`OL17386124W 'Spice Wolf'`. `The Umbrella Academy, Vol. 2` gains
`OL17303667W 'The Umbrella Academy'`. Those are `omnibus_vs_parts`
relationships, not matches. Shipping the volume strip on its own would convert
"no answer" into "wrong answer", which is worse.

The date-range strip is the clean half: `The Illustrator In America, 1860 2000`,
`History Of The Makhnovist Movement, 1918 1921`, `India In The Persianate Age,
1000–1765`. Single books whose title carries the period they cover, held in OL
without it. 42 usable gains, low risk.

### Recommendation

- **Ship the date-range strip** as an extra blocking key. Small, clean.
- **Do not ship the volume strip until the scorer can compare volume numbers.**
  It is a recall gain that hands the scorer a precision problem it cannot
  currently solve.
- **Repair the 2,760 subtitle repeats** in the data, at migration time. They
  cost nothing to fix and they restore `title_fp_nosub` to working order.

## When one title covers several books

Something also truncated, and here the responsibility **is** ours: Goodreads
carries the full title *Hellmaw: Throckmorton's Trick* and book #160918 is
stored as `Hellmaw`, the series name alone. Three of our rows are
titled just `Hellmaw`, with three different ISBNs and three different Goodreads
ids: three books in a series collapsed onto one string.

**146 (author, title) pairs are held by more than one Book row, covering 387
books.** That symptom has two opposite causes and they need opposite repairs —
a truncated series title must be **split**, a twice-imported book must be
**merged** — and the title alone cannot tell them apart.

Open Library arbitrates. `classify_title_collision` resolves each row's
identifiers to OL works and asks whether the rows landed on the same one:

| Verdict | Groups | Books | Meaning |
|---|---:|---:|---|
| `unresolved` | 70 | 146 | fewer than two rows resolve; OL has no opinion |
| `duplicate_rows` | 55 | 121 | rows share a work — **merge** candidates |
| `distinct_books` | 18 | 49 | rows land on disjoint works — **truncation** |
| `mixed` | 3 | 71 | both defects in one group |

**30 groups / 68 books are high-confidence merges** — every resolved row lands
on exactly one OL work and they all agree. Those are safe to hand to the
existing record-merge tooling. The rest are not.

### The three `mixed` groups are the three biggest

| | Title | Stored author |
|---:|---|---|
| **40×** | `d ceased` | `Tom     Taylor` |
| **28×** | `jo jo's bizarre adventure` | `Nobuyoshi Araki` |
| 3× | `new x men` | Nunzio DeFilippis |

Between them they hold 71 of the 387 books, and neither repair is safe applied
wholesale — some rows in each group share a work and some do not.

The JoJo group carries a **second, unrelated defect**: *JoJo's Bizarre
Adventure* is by **Hirohiko** Araki. Twenty-eight of our rows credit
**Nobuyoshi** Araki, a real person but a photographer. Open Library holds 287
works by Hirohiko and 145 by Nobuyoshi, so both exist and the wrong one was
chosen. This is the `surname_collision` class of `books-author-disagreements.md`
concentrated in one bucket — that sweep found `nobuyoshi araki` to be its
**third-largest** disagreeing author at 47 books, and 28 of them are this one
series.

### Limit: an intersection gets cheap when a row is noisy

The `duplicate_rows` verdict asks whether resolved rows share *any* work, so a
row resolving to a dozen works can produce an intersection by chance. `X Men` by
Chris Claremont lands there with rows resolving to 13 and 7 works respectively,
and is almost certainly truncation rather than duplication.

Of the 240 resolved rows, 185 land on exactly one work and only 13 land on four
or more, so the effect is small — but it is the reason the high-confidence
subset above exists, and the reason to use that subset rather than the 55.

## Why a lone year is never stripped

`1984` is a whole title. `The War Book Of The German General Staff 1914` is
about its year. Only a *range* comes off, and only when it runs forwards.

That last clause is not hypothetical. Exactly one exported title has a backwards
pair — #13733, Bellamy's *Looking Backward, 2000-1887*, where the years run that
way because the novel looks back from 2000 to 1887. Stripping it would be a net
**loss**: `looking backward 2000 1887` sits on 37 OL works and blocks today,
while `looking backward` sits on 57, which is over `MAX_TITLE_FP_FREQ` — the
rule would suppress it and the book would go from 37 candidates to none.

## Not every defect is ours

Four of these have been traced to their source by opening the Goodreads page
the row was imported from, and they do not all point the same way.

| Book | Goodreads holds | Whose defect |
|---|---|---|
| #160918 `Hellmaw` | the full `Hellmaw: Throckmorton's Trick` | **ours** — truncated on import |
| #106848 `D Ceased` | the full `DCeased: War of the Undead Gods #6` | **ours** — the word was split |
| #43599, year 1975 | first published 1971, this edition 1977 | **ours** — neither year is 1975 |
| #145894 `The Complete Work Of Meister Eckhart` | **the same wrong title** | **upstream** — copied faithfully |

Book #145894 is the one that matters for planning. Open Library holds the book
three times as *The Complete Mystical Works of Meister Eckhart*; Goodreads has
the title wrong on its own record, and our row reproduces it exactly. Nothing
in our code did this.

**The two kinds need different plans.** A defect we introduced is fixed once, at
migration. A defect we inherited returns on the next sync from the same source,
so the repair has to live in the importer as a rule rather than in a one-off
backfill — and the correction has to survive being overwritten.

**Book #143219's origin is not established.** Our title matches the book's
*real* title (`Andrew Jackson and the Course of the American Empire`) while
Goodreads shows the Johns Hopkins reissue title (`Andrew Jackson: The Course of
American Empire`), and neither source has `Volume I`. It came from somewhere
else, probably the legacy books app. It is used above as an example of the
*shape* of the defect, not as evidence about its cause.

## Known limits

- **Gains are counted against `title_fp` only.** A book with no title candidate
  may still be reachable by identifier; these 2,432 are books the *title* rules
  miss, not books the matcher misses.
- **"Gains a candidate" is not "gains the right candidate."** Nothing here
  verifies the work found is the correct one; see the volume-vs-series problem
  above.
- **English volume words only.** `Band`, `Tome`, `том` are not recognised, so
  the volume count under-reports on non-English titles.
- **Cause is not attributed at scale.** Four rows were traced to their source
  by hand. Nothing here establishes what share of the 5,427 came from our code
  versus from the source data, and the counts should not be read as a measure
  of importer bugs.
- **The subtitle-repeat count is a lower bound.** It requires the subtitle
  column to still hold the text. A row whose subtitle was moved into the title
  and left null is invisible to this check.
