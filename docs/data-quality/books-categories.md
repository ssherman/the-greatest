# Books subjects and locations: measurements

Measured in dev on 2026-10-11. The numbers describe that moment, not a rule: regenerate with the
queries below before acting on them. Spec: `docs/superpowers/specs/2026-10-11-books-category-cleanup-design.md`.

`category_type` 1 is location and 2 is subject. Run these against a development or restored copy.
They only read.

## What the data looked like

| | live | on 0 books | on 1 book | on 2-4 | on 5-19 | on 20+ | links | links on 20+ |
|---|---|---|---|---|---|---|---|---|
| location | 17,154 | 805 | 8,815 | 3,875 | 2,206 | 1,453 | 458,989 | 420,146 |
| subject | 45,100 | 1,054 | 22,361 | 11,083 | 6,805 | 3,797 | 1,115,678 | 1,001,657 |

About 92% of links sit on categories with 20 or more books, and half of each vocabulary is on one
book. Junk seen in the live data: truncated names (`Japan (`, `61)`; 721 locations contain a
bracket), 193 location and 457 subject twin clusters, qualified names (`Paris, France`), subjects
stored as locations (`Hope`, `Media`), `Fictional Location` on 39,267 books, 441 lowercase-initial
subjects, and 1,653 books with more than 25 locations (maximum 361). The 1,653 is the 2026-10-11 count; the over-tagging query below counts differently and gave 1,788 over 25, 5,124 over 15 and a maximum of 361 in dev later.

## Usage distribution per type (live categories, real link counts)

```sql
WITH c AS (
  SELECT c.id, c.category_type,
         (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id) AS n
  FROM categories c
  WHERE type = 'Books::Category' AND NOT deleted AND category_type IN (1, 2)
)
SELECT category_type, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE n = 0) AS zero, COUNT(*) FILTER (WHERE n = 1) AS one,
       COUNT(*) FILTER (WHERE n BETWEEN 2 AND 4) AS two_4, COUNT(*) FILTER (WHERE n BETWEEN 5 AND 19) AS five_19,
       COUNT(*) FILTER (WHERE n >= 20) AS ge20, SUM(n) FILTER (WHERE n >= 20) AS links_ge20, SUM(n) AS links
FROM c GROUP BY 1;
```

## Junk patterns

```sql
SELECT category_type,
       COUNT(*) FILTER (WHERE name ~ '[()\[\]]') AS brackets,
       COUNT(*) FILTER (WHERE name ~ '[,;:/]') AS punctuation,
       COUNT(*) FILTER (WHERE name ~ '[^\x01-\x7F]') AS non_ascii,
       COUNT(*) FILTER (WHERE name ~ '^[a-z]') AS lowercase_start
FROM categories
WHERE type = 'Books::Category' AND NOT deleted AND category_type IN (1, 2)
GROUP BY 1;
```

## Case and punctuation twin clusters

```sql
WITH c AS (
  SELECT category_type, lower(regexp_replace(name, '[^[:alnum:]]', '', 'g')) AS k
  FROM categories
  WHERE type = 'Books::Category' AND NOT deleted AND category_type IN (1, 2)
)
SELECT category_type, COUNT(*) AS clusters, SUM(n) AS categories
FROM (SELECT category_type, k, COUNT(*) AS n FROM c GROUP BY 1, 2 HAVING COUNT(*) > 1) x
GROUP BY 1;
```

## Books by number of direct location links (over-tagging)

```sql
SELECT COUNT(*) FILTER (WHERE n > 15) AS over_15, COUNT(*) FILTER (WHERE n > 25) AS over_25, MAX(n) AS max
FROM (
  SELECT ci.item_id, COUNT(*) AS n
  FROM category_items ci JOIN categories c ON c.id = ci.category_id
  WHERE ci.item_type = 'Books::Book' AND ci.source <> 2 AND c.category_type = 1 AND NOT c.deleted
  GROUP BY 1
) x;
```

## Production cleanup run, 2026-10-15

Run label `2026-10-12-prod`. Decision counts as applied; the before-and-after vocabulary sizes need
the queries above run against a fresh restore.

| stage | applied |
|---|---|
| rules | 1,362 (759 merges, 560 renames, 43 fragment deletes) |
| AI wave 1 | rename 2,948, merge 34,863, retype 336, set_parent 14,847, delete 744, keep 8,425; 127 parents created |
| AI wave 2 | rename 6, merge 190, retype 7, set_parent 133, delete 52, keep 63 |

- 69 merges went stale on purpose in wave 1: 68 broken merge cycles, plus one keep staled by a hand fix.
- 2 decisions failed at propose time and 3 at apply time, all safety refusals (see the runbook).
- 21 decisions were rejected at review: 4 in wave 1 (`Providence` and `Queens` retypes, which hold
  Lovecraft and Spider-Man books; the `Aleister Crowley` and `Sigmund Freud` deletes) and 17 wave-2
  subject-to-location retypes.
- `New York` (11,986 books) merged into `New York City`. 3,910 of New York City's 4,210 books
  already carried both tags. About 378 of the merged books also carry a place outside the city
  (Long Island, Albany, Buffalo) and now say New York City too.
- Calibration (dev, 200 tail categories): two one-at-a-time passes agreed on 86.5% of locations and
  88.5% of subjects. Batch size 10 agreed 83-84% for locations (verdict agreement 98.5% against a
  99.0% baseline) and 76-78.5% for subjects (action agreement 89% against 95.5%).
- The location trim's 30 worst books (187-361 locations) were reviewed in a dry run: global surveys
  kept nothing, focused books kept their real settings.
