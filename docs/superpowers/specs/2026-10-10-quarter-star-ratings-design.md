# Quarter-Star Ratings — Design

Date: 2026-10-10. Status: approved section by section in brainstorming; awaiting review of this
written spec.

## 1. Why this exists

On 2026-10-05 Goodreads launched quarter-star ratings: a reader can now rate a book 0.25 to 5.0 in
0.25 steps
([announcement](https://www.goodreads.com/blog/show/3202-readers-1-request-half-and-quarter-star-ratings-are-here)).
Existing whole-star ratings stay as they are unless the reader edits them. We mirror it: our
reviews take fractional ratings, entered the way Goodreads enters them, and the Goodreads import
carries them across exactly.

### What Goodreads does (verified 2026-10-10)

- **Input.** On the web, hovering over a star fills it a quarter at a time (¼, ½, ¾, full) as the
  pointer moves across it; clicking commits. Whole stars still work. Tested by the owner.
- **Display.** Each star is its own SVG: a full outline star with a filled shape over it. A 0.5
  fills exactly the left half of the first star (a cut at the star's vertical midline, so the cut
  is by width). The accessible name is `"Rating 0.5 out of 5"` on a `role="img"` wrapper.
  Goodreads' input stars are much larger than ours.
- **Histogram.** Still five bars. Per the announcement, `.25` and `.5` round down and `.75` rounds
  up; the 1-star bar holds 0.25 to 1.5.
- **Library export.** Verified against a real export taken on 2026-10-10:
  - `My Rating` now holds decimals: `3.75`, `4.25`, and `4.0` for a whole star. `0` still means
    "not rated". One sample cannot tell whether every whole star is now written `4.0` or only ones
    set since the launch, so both `4` and `4.0` must parse.
  - The `Average Rating` column is gone from the header. We never read it, and it is not in
    `ExportFile::REQUIRED_HEADERS`, so nothing breaks.

### What is broken today

- `reviews.rating` is an integer with `CHECK (rating >= 1 AND rating <= 5)` and
  `numericality: {only_integer: true}`.
- `Books::Goodreads::ExportRow` reads `My Rating` with `Integer(value, 10, exception: false)`. Every
  rated row in a current export, **including `4.0`**, is dropped with a note
  (`"unreadable My Rating dropped: 3.75"`). The row still imports, but without its rating.
- Books has not launched, so no member has lost a rating on our site yet.
- The legacy site's importer (`../the-greatest-books/admin/app/lib/goodreads_library_parser.rb:246`)
  does `row["My Rating"].to_i`. Since 2026-10-05:
  - a 3.75 uploaded there became a legacy review rated **3**
  - a 0.25 or 0.5 became 0 and **no review was created at all**, even with review text, because it
    requires `rating >= 1`

  The weekly `data_migration:sync` copies those truncated reviews into our database. §5.4 repairs
  them.

## 2. Decisions

| Question | Decision |
|---|---|
| Precision | Quarter stars in the UI, the same as Goodreads. |
| Storage | `decimal(3,2)`, `0 < rating <= 5`. **No quarter-step constraint**: nothing needs one. The histogram rule and the star display work for any decimal, our input only produces quarters, and Goodreads only exports quarters. A stray `3.3` from an import is stored as 3.3. |
| Input on desktop | Hover previews in quarter steps, click commits. |
| Input on touch | The same control: the touch point sets the value, dragging along the row adjusts it live, lifting commits. |
| Histogram | Five bars, Goodreads' rule (§4.3). |
| Legacy truncation | Repaired by a dedicated replay step, `books:goodreads_replay:repair_ratings` (§5.4). |
| Recommendation thresholds | Unchanged values, compared against the exact decimal (§6.2). |

Rejected storage alternatives:

- **Integer quarter-units (1..20).** Every consumer would have to divide by 4, and missing one turns
  a 3-star review into a 12-star one. About 15 places read ratings.
- **Float.** Inexact representation makes the equality checks unreliable.

## 3. Data model

### 3.1 `reviews.rating`

- Migration: `change_column :reviews, :rating, :decimal, precision: 3, scale: 2`.
- Replace the check constraint `reviews_rating_range` (`rating >= 1 AND rating <= 5`) with
  `rating > 0 AND rating <= 5`, keeping the same constraint name. `reviews_rating_or_body` stays as
  it is.
- Every existing rating is an integer from 1 to 5 and satisfies the new constraint, so no data is
  rewritten beyond the type change.
- The `ALTER COLUMN TYPE` rewrites the table under an `ACCESS EXCLUSIVE` lock. The table holds about
  151k legacy reviews plus imports, so the lock lasts on the order of a second.
- Only books has reviews (`Reviews::Registry`), and books has not launched. Music and games do not
  read this table.
- The migration must be reversible. `down` casts back to integer and **refuses** if any rating is
  fractional, rather than silently truncating.

### 3.2 `Review` model

- Validation: `numericality: {greater_than: 0, less_than_or_equal_to: 5}, allow_nil: true`. The
  `only_integer` option is removed.
- Rails rounds assignment to scale 2, so `3.333` is stored as `3.33`.
- **`Review.rating_bucket(value)`** maps a rating to its histogram bar, 1..5 (§4.3). Every bucketed
  consumer uses it: summaries, My Reviews filter, stats and profile strip.
- **`Review.format_rating(value)`** returns display text with trailing zeros dropped: `4` → `"4"`,
  `3.5` → `"3.5"`, `3.75` → `"3.75"`. `Review#formatted_rating` delegates to it.
  - **This is a correctness fix, not a nicety.** Under Rails a whole-star `BigDecimal` prints
    `"4.0"` (fractional values print as `3.75`), so a view that interpolates a raw rating would
    say "Rated 4.0 out of 5". The formatter prevents that.
  - Display strings belong on models (project convention).

### 3.3 `review_summaries`

- `ratings_sum` becomes `decimal(10,2)`.
- `ratings_count` and `rating_1_count`..`rating_5_count` stay integers, since they are still counts
  of five buckets.
- `ReviewSummary#average_rating` is unchanged in meaning.

### 3.4 `books_goodreads_import_rows.rating`

- Becomes `decimal(3,2)`.
- Model validation `inclusion: {in: 0..5}` becomes
  `numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 5}, allow_nil: true`. `0`
  still means Goodreads' "not rated".

### 3.5 JSON

Rails serialises `BigDecimal` as a string (`"3.75"`). Every JSON payload that carries a rating sends
a number (`rating&.to_f`):

- `ReviewStateController#serialize` (fills the dialog)
- the My Reviews row JSON consumed by `my_reviews_controller.js`

## 4. Display

### 4.1 `Reviews::StarsComponent`

- Change from one filled strip clipped to `rating / 5` across the whole row to **one fill per
  star**. Star `i` (0-based) is filled to `clamp(rating − i, 0, 1)`, a width cut as Goodreads does.
- This removes the drift the inter-star `gap-px` causes today: at `size-4` a 3.5 fills about 49% of
  the fourth star.
- Sizes are unchanged at every existing call site: summary line, single review, My Reviews row,
  widget, admin show.
- Fill stays a single colour (`text-warning` over `text-base-content/30`), so the information is
  carried by extent and the printed number, never by hue.
- The label distinguishes two cases:
  - **A single rating** reads its exact value: `"3.75 out of 5 stars"`, via `Review.format_rating`.
  - **An average** keeps one decimal place: `"4.1 out of 5 stars"`.

  Today the component rounds everything to one decimal, which would read a single 3.75 as "3.8".
  Callers say which case they are; the default stays "average", so existing average call sites need
  no change.

### 4.2 Text that prints a rating

These switch to `formatted_rating` / `Review.format_rating`:

- `Reviews::ReviewComponent` (`"Rated N out of 5"`, review_component.rb:28)
- `Reviews::WidgetComponent` (widget_component.rb:41) and `widget_controller.js` (:95-97 fill,
  :110-111 label). The JS uses the same per-star fill and the same trailing-zero formatting as the
  server.
- `admin/reviews_base/index.html.erb:31`, `admin/reviews_base/show.html.erb`,
  `admin/users/show.html.erb:208`

### 4.3 Histogram buckets

Goodreads' rule: round to the nearest whole star, ties round **down**, and the floor is 1. So
0.25..1.5 → 1, 1.75..2.5 → 2, 2.75..3.5 → 3, 3.75..4.5 → 4, 4.75..5 → 5. For values that are not
quarters the same rule holds (2.6 → 3, 2.4 → 2).

- SQL: `GREATEST(1, CEIL(rating - 0.5))`
- Ruby: `[1, (value - 0.5).ceil].max`

Consumers:

- `Services::Reviews::SummaryRecalculator` (:33-40). `SUM(rating)` into the decimal `ratings_sum`,
  and `COUNT(*) FILTER (WHERE <bucket> = n)` for n in 1..5 in place of `rating = n`.
- `Reviews::HistogramComponent` keeps its `5.downto(1)` bars; the buckets it reads are now correct.

## 5. Input and import

### 5.1 The rating control

This replaces the five `<button data-rating>` elements in `Reviews::ModalComponent` and the star
logic in `reviews--modal`.

**Markup.**

- One focusable element with `role="slider"`, `aria-valuemin="0.25"`, `aria-valuemax="5"`, and
  `aria-valuenow` when rated. `aria-valuetext` is `"3.75 stars"` or `"Not rated"`.
- It contains five stars at about 40px each (`size-10`; 24px today), drawn with the §4.1 per-star
  fill.
- A visible readout beside them shows `3.75` or `Not rated`.
- The hidden `review[rating]` field keeps its name and holds `3.75`.
- The stars are larger only in this dialog.

**Value from position.**

- Find the star under the pointer, then the quarter of that star, and round up:
  `value = star_index + ceil(4 × x_within_star / star_width) / 4`, clamped to 0.25..5.
- So the first sliver of star 4 is 3.25 and its right edge is 4.
- A pointer in a gap between stars, or past either end, snaps to the nearest valid value.

**Mouse.**

- `pointermove` previews the value (fill and readout follow the pointer).
- `click` commits.
- `pointerleave` restores the committed value.

**Touch / pen.**

- `pointerdown` sets the value and captures the pointer.
- `pointermove` updates it live.
- `pointerup` commits.
- The row has `touch-action: pan-y`: a horizontal drag rates, a vertical swipe still scrolls the
  dialog.

**Keyboard.**

| Keys | Effect |
|---|---|
| ←/↓ and →/↑ | −/+ 0.25 |
| PageDown / PageUp | −/+ 1 |
| Home / End | 0.25 / 5 |

From "not rated", the first increase gives 0.25. The existing "Clear rating" button stays the way to
remove a rating.

**Structure.**

- A new Stimulus controller, `reviews--star-input`, does one job: it turns pointer and key events
  into a value, writes the hidden field, and dispatches a `change` event.
- `reviews--modal` sets the initial value when it opens the dialog. That value can be an imported
  4.25 or a legacy 4, from the numeric JSON in §3.5. The modal listens for `change` to show or hide
  "Clear rating", and loses `setRating` and its star-toggling code.
- Server side, `ReviewsController` already permits `:rating`, and `"3.75"` casts to `BigDecimal`.

### 5.2 Parsing (`Books::Goodreads::ExportRow`)

- `My Rating` gets a decimal reader in place of `integer(..., minimum: 0, maximum: 5)`:
  - parse with `BigDecimal(value, exception: false)`
  - **require `finite?`**, because `BigDecimal("NaN")` and `BigDecimal("Infinity")` parse
  - require `0..5`
  - round to 2 places
- Anything else is dropped with the existing `"unreadable My Rating dropped: <value>"` note.
- Accepted: `4`, `4.0`, `3.75`, `3.333` (→ 3.33), `0` (unrated).
- The other integer columns (`Number of Pages`, `Read Count`) keep the integer reader.

### 5.3 Writing reviews (`Services::Books::GoodreadsImports::WriteLibrary`)

- Three uses of `row.rating.to_i.positive?` in `write_reviews` / `write_review` become
  `row.rating&.positive?`.
- **Without this change a 0.25 or 0.5 is treated as unrated and discarded.** `0.25.to_i` is 0.

### 5.4 Repairing legacy truncation (dedicated replay step)

**Background.**

- Reviews copied from legacy keep their legacy ids, all below
  `Services::BooksMigration::RESERVED_CEILINGS["reviews"]` (250,000). New-app reviews are at or
  above it.
- `write_reviews` leaves any existing review alone, and legacy replay imports are created already
  complete, so they never pass through `WriteLibrary`. The repair is its own step,
  `Services::Books::GoodreadsReplay::RepairTruncatedRatings`
  (`books:goodreads_replay:repair_ratings`), run after the final `apply` of every pass.

**Rule.** For a (user, book) with a replay-import row and an existing review, update that
review's rating to the CSV value **only when all four hold**:

1. the import is `source: legacy_replay` (never a member's own import); this is the candidate query
2. the existing review's id is below the reserved ceiling (legacy origin)
3. the CSV rating on the winning row is fractional. The winner is chosen among all the user's
   rated replay rows for the book (latest upload, then latest Date Read, then lowest row number),
   so a later whole-number re-rating beats an earlier fraction
4. the stored rating equals the CSV rating rounded down: `stored == csv.floor`, which is what the
   legacy `to_i` produced

The match is that precise, so a rating the member deliberately changed is never touched. The step
recalculates each repaired book's summary once, after all repairs. The body, title and timestamps
are not touched.

**Interaction with the weekly sync.**

- `ReviewMigrator` (sync mode) **overwrites** legacy-origin reviews from legacy each week, so it
  puts the 3 back.
- `repair_ratings` runs after each sync's replay pass (after the final `apply`, once merges have settled which book a review
  sits on), and it restores 3.75.
- Each cycle therefore ends correct, including the final launch pass, after which legacy is shut
  down. Running the replay twice in a row changes nothing the second time.

**0.25 and 0.5 are a known gap.** Legacy created no review for a rating under 1 (its
`rating >= 1` check), and replay imports never write reviews, so those ratings are not restored.
Out of scope for this step.

## 6. Other consumers

### 6.1 My Reviews

- `Reviews::MyReviewsQuery` (:19, :51-56): the `?rating=N` filter keeps `N` as a bucket number 1..5
  and filters with the §4.3 bucket expression. `rating=4` returns 3.75 through 4.5.
- Sorting by rating (:78-79) already works on decimals.
- `Reviews::MyReviewsStats` (:7-48) groups by the bucket expression.
- `My::ProfileStripComponent` (`RATINGS = 1..5`) counts by bucket.
- `my_reviews_controller.js:25` keeps `Number(row.rating)`, now fed a number (§3.5).

### 6.2 Recommendations

Thresholds keep their configured values and compare the **exact** rating. A reader who chose 3.75
over 4 meant "not quite 4", so a 3.75 is not a strong like at `because_of_rating: 4` and is not
held out at the evaluation threshold of 4.

- `Recommendations::Books::PositivePairs` (:14, :48): `@min_rating = min_rating.to_i` becomes a
  decimal, so a threshold like 3.5 can be configured later. `collaborative_min_rating: 3` is
  unchanged.
- `Recommendations::Books::Adapter` (:26-34): the weight `rating_slope * (rating - 3)` is already
  continuous. Convert with `to_f` where it meets float maths.
- `interaction.rb`, `evaluation.rb`, `signals/collaborative.rb` and `reranker/series_rule.rb`
  compare against the configured thresholds unchanged. Check that each compares rather than
  casting with `to_i`.
- `Recommendations::Export` writes only `user_id,item_id` pairs and is untouched. The Python
  recommender never sees ratings.

### 6.3 Seed data

`lib/tasks/e2e.rake:177` (`rating = (n % 5) + 1`) also seeds some fractional ratings (for example,
every third review gets `+ 0.75` capped at 5) so E2E pages render them.

## 7. Testing

Every rule gets cases on both sides of its boundary, so a test cannot pass merely because the
fixtures never contain the case that should fail.

**Migration / model**

- Existing integer ratings survive the migration unchanged.
- The constraint accepts 0.25, 3.33 and 5, and rejects 0, -1 and 5.01. The model validation agrees.
- `Review.rating_bucket` at 0.25, 1.5, 1.75, 2.5, 2.75, 4.5, 4.75 and 5.
- `Review.format_rating`: 4 → "4", 3.5 → "3.5", 3.75 → "3.75", and a whole-star case asserts "4" and not "4.0".

**Summaries / display**

- `SummaryRecalculator` buckets the boundary values correctly and keeps an exact decimal sum.
- `StarsComponent` at 3.75: three full stars, the fourth 75% filled, the fifth empty. A single
  rating's label is exact; an average's label has one decimal.
- `ReviewStateController` JSON carries `3.75` as a number.

**Import**

- `ExportRow` accepts `4`, `4.0`, `3.75`, `3.333` → 3.33 and `0`. It drops `5.5`, `-1`, `NaN`,
  `Infinity` and `abc`, each with a note.
- A new fixture, `test/fixtures/files/goodreads/quarter_star_export.csv`, uses the current header
  (no `Average Rating`) and the ratings `3.75`, `4.25`, `4.0`, `0`, as in the real export.
- `WriteLibrary` creates a review for a 0.25 rating. This is the regression test for the `to_i`
  bug.

**Repair (§5.4)**

- Fires when all four conditions hold.
- One "does not fire" case per condition: a member import, an id at or above the ceiling, a
  whole-number CSV rating, and a stored rating that is not `csv.floor`.
- A second run is a no-op.
- The summary is recalculated for a repaired book.

**My Reviews / recommendations**

- `MyReviewsQuery` `rating=4` includes 3.75 and 4.5, and excludes 3.5 and 4.75.
- `MyReviewsStats` buckets the same way.
- `PositivePairs` with a 3.5 threshold includes 3.75; with 4 it excludes 3.75.

**E2E (Playwright, `e2e/tests/books/`)**

- Hovering across a star previews quarter values.
- Arrow keys step ±0.25.
- In a touch context (`hasTouch`), a tap sets a value and a drag adjusts it.
- A saved 3.75 shows on the book page and in My Reviews, and reopening the dialog shows 3.75.
- Update the existing specs that click `review-star-button` (`reviews.spec.ts`,
  `account/reviews-write.spec.ts`, `account/my-reviews.spec.ts`, `admin/reviews.spec.ts`,
  `member/recommendations.spec.ts`) to the new control.

**Before done:** `bin/rails test`, `bin/rails test:system` and `bundle exec standardrb`.

## 8. Docs to update

- `docs/features/goodreads-import.md`: `My Rating` is decimal, and the §5.4 repair.
- `docs/features/recommendations.md`: thresholds compare the exact decimal rating.
- There is no reviews feature doc. The 2026-08-09 reviews spec is historical and is not edited.

## 9. Out of scope

- Changing the legacy site. Its `reviews.rating` column is integer and the site is being retired.
- Fractional ratings for music or games. They have no reviews.
- A half-star-only mode or a per-user precision setting.
