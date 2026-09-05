# Books: single-issue comics, and why they should not match

**Measured 2026-09-04** against the `2026-07-31` Open Library artifact and a
development database refreshed from production (157,805 exported books).

These arrive through ordinary, valid Goodreads imports. They are real rows and
they belong in the catalogue. They are also, for the most part, permanently
unmatchable — and the useful thing the matcher can do with them is **abstain
confidently** rather than reach for the collected edition sitting next to them.

## The three shapes

1,048 exported titles carry a `#N`. `openlibrary.audit.titles.classify_issue_title`
splits them, because they want opposite handling:

| Shape | Books | Example | What the matcher should do |
|---|---:|---|---|
| `single_issue` | **974** | `Batman  #614` | abstain |
| `series_annotation` | 26 | `Ranma 1/2, Vol. 20 , #20)` | strip it, then match normally |
| `collected_range` | 14 | `The Dark Tower #1 3` | match the omnibus |

The remaining `#` titles are not numbered at all — `The #1 Lawyer`, `#Girlboss`,
`C#` — and classify as `none`.

`series_annotation` is a separate defect worth its own note. Goodreads writes
`Title (Series #N)`; the importer kept the closing bracket and lost the opening
one, so `Ranma 1/2, Vol. 20` arrives as `Ranma 1/2, Vol. 20 , #20)`. Those are
ordinary books — a manga volume is a volume, not an issue — and they match once
the annotation is gone. All 26 in the export have the orphan bracket; none is
well-formed.

## Identifier coverage of the 974

| | Books |
|---|---:|
| Goodreads id only | **774** |
| carries an ISBN | 200 |
| no identifier at all | 0 |

## Open Library's coverage is real but uneven

**63,315 OL works have a `#N` title**, so Open Library plainly does catalogue
single issues. It just has not catalogued the ones we hold:

| Our series | Our books | OL works titled `<series> #N` |
|---|---:|---:|
| The Walking Dead | 192 | **0** |
| Saga | 69 | 9 |
| Descender | 32 | **0** |
| House of Slaughter | 26 | 17 |
| Nightwing | 19 | **0** |
| Ascender | 18 | **0** |
| Black Panther | 18 | 1 |
| Batman | 12 | 3 |
| Fantastic Four | 11 | 2 |

The largest single series in the class — 192 issues of *The Walking Dead* — has
**no** issue-level presence in Open Library at all.

## Why these are the most valuable cases in the evaluation set

The collected edition is almost always in Open Library under a nearly identical
name, which is exactly the trap:

- `Batman #614` is one issue of the *Hush* arc (#608–619). OL has no
  `Batman #614`, but it has `Batman: Hush` five times over — `OL818834W`,
  `OL21124109W`, `OL16586709W` and more.
- `DCeased: War of the Undead Gods #6` is a 26-page Kindle single. OL has no
  such work, but holds the collected `DCeased` trades three times.

Matching either to its trade is a **false merge**: it destroys a real
distinction in our data to manufacture a result. A `no_match` label on one of
these is a case that will catch a matcher tuned too aggressively, and nothing
else in the evaluation set teaches confident abstention.

## The open question is policy, not matching

Nothing the matcher does can find a work Open Library does not have. The
decision is whether these rows should carry something — a `book_kind`, or a
flag the importer sets — that tells candidate generation not to try, rather
than spending blocking on 974 books that cannot match.

That is a schema and importer decision, not a scoring one, and it is not made
here.

## Known limits

- **The 974 is a floor.** It counts titles ending in `#N`. An issue recorded
  without one — `Amazing Fantasy #15  1st Appearance Of Spider Man`, where
  descriptive text follows the number — classifies as `none` and is not counted.
- **Per-series OL counts are prefix matches** on `<our series title> #`. A
  series Open Library files under a different name (`Walt Disney's Uncle
  Scrooge #319` versus `Uncle Scrooge #319`) is undercounted.
- **Coverage is not identity.** `House of Slaughter` having 17 OL works titled
  `#N` does not mean any of them is one of our 26.
- **No claim is made about whether these should be in the catalogue.** They
  come from valid imports and the question here is only what the matcher does
  with them.
