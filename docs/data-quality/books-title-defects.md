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

The old importer concatenated. Book #143219 is stored as

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

## Why a lone year is never stripped

`1984` is a whole title. `The War Book Of The German General Staff 1914` is
about its year. Only a *range* comes off, and only when it runs forwards.

That last clause is not hypothetical. Exactly one exported title has a backwards
pair — #13733, Bellamy's *Looking Backward, 2000-1887*, where the years run that
way because the novel looks back from 2000 to 1887. Stripping it would be a net
**loss**: `looking backward 2000 1887` sits on 37 OL works and blocks today,
while `looking backward` sits on 57, which is over `MAX_TITLE_FP_FREQ` — the
rule would suppress it and the book would go from 37 candidates to none.

## Known limits

- **Gains are counted against `title_fp` only.** A book with no title candidate
  may still be reachable by identifier; these 2,432 are books the *title* rules
  miss, not books the matcher misses.
- **"Gains a candidate" is not "gains the right candidate."** Nothing here
  verifies the work found is the correct one; see the volume-vs-series problem
  above.
- **English volume words only.** `Band`, `Tome`, `том` are not recognised, so
  the volume count under-reports on non-English titles.
- **The subtitle-repeat count is a lower bound.** It requires the subtitle
  column to still hold the text. A row where the importer moved it into the
  title and left `subtitle` null is invisible to this check.
