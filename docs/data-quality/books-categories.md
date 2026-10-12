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
subjects, and 1,653 books with more than 25 locations (maximum 361).

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
