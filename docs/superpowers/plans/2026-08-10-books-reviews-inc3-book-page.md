# Books Reviews — Increment 3: Book Page Read Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the 141,869 migrated reviews visible on `/book/:slug` — a compact rating line under the rank, and a `Ratings & Reviews` card at the bottom of the right column holding a per-star histogram and every written review, newest first.

**Architecture:** Five small ViewComponents in a global `Reviews::` namespace (`Stars`, `SummaryLine`, `Histogram`, `Review`, `Card`), a render-time counterpart to `Services::Reviews::BodySanitizer`, one Stimulus controller for spoiler reveal, and two extra indexed queries in `Books::BooksController#show`. No new routes, no pagination, no user-specific state — the page stays edge-cacheable exactly as it is today.

**Tech Stack:** Rails 8.1.3.1, ViewComponent, Tailwind CSS 4 + DaisyUI 5, Stimulus (Rollup IIFE bundles), Lucide icons via `rails_icons`, Minitest + fixtures + Mocha, Playwright, Standard (standardrb).

**Spec:** `docs/superpowers/specs/2026-08-09-books-reviews-design.md` (see the `Book page — /book/:slug` section, amended 2026-08-10 with this increment's decisions)
**Builds on:** increment 1 (PR #213 — `Review`, `ReviewSummary`, `BodySanitizer`, `SummaryRecalculator`) and increment 2 (PR #215 — the migration, run in production 2026-08-10).

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Working branch is `books-reviews-inc3`, cut from `main` in the main checkout (no worktree).
- Lint with `bundle exec standardrb`. **Not** `bin/rubocop`. Never run brakeman.
- Use generators. Components: `bin/rails generate view_component:component Reviews::Stars rating`. This repo has **no** `--sidecar` config, so the generator writes `app/components/reviews/stars_component.rb`, `app/components/reviews/stars_component.html.erb` and `test/components/reviews/stars_component_test.rb` — the flat layout `Books::CardComponent` uses. Do not hand-create these files.
- **This increment adds no database migration and no route.** The schema shipped in increment 1; the surface hangs off the existing `GET /book/:slug`.
- Components live in the **global** `Reviews::` namespace (plural module, per `docs/view-components.md`), matching `UserLists::` — `Review` is a root-namespace model and music/games reuse these later.
- The book page is edge-cached for 24 hours by `Cacheable#cache_for_show_page`. **Nothing rendered in this increment may vary by visitor.** Signed-in state, "your rating", and the write flow all belong to increment 4.
- Never encode meaning in hue alone. The histogram is one colour; the stars are one colour. Fill *position* and the printed number carry the information.
- Controller tests assert behaviour — status codes, assigns, query counts, and the presence of a stable `id`/`data-testid`. Never assert copy or CSS classes there; that belongs in component tests.

## Measured data this increment is designed against (dev DB, 2026-08-10)

| Metric | Value |
|---|---|
| `review_summaries` rows | 53,630 |
| Books with ≥1 written review | 11,663 |
| Books with **no** rating at all | 72,659 of 126,289 |
| **Most written reviews on one book** | **37** — *The Great Gatsby*, book 38, slug `the-great-gatsby` |
| Books with >20 written reviews | 12 |
| Books with >50 written reviews | **0** |
| Reviews carrying a title | 404 of 141,869 |
| Bodies containing a spoiler span | 118 |
| Distinct writers of text reviews | 364 (56 have a display name) |
| Book 38 summary | 450 ratings, sum 1,782, avg 3.96, text 37, histogram 9 / 27 / 83 / 183 / 148 |
| A book with a spoiler body | 17,447, slug `room-for-murder` |

These figures are why there is no pagination and no attribution. Do not add either.

---

### Task 1: Vendor the star icon and build `Reviews::StarsComponent`

**Files:**
- Create: `web-app/app/assets/svg/icons/lucide/outline/star.svg`
- Modify: `web-app/app/assets/svg/icons/README.md` (the icon table)
- Create: `web-app/app/components/reviews/stars_component.rb`
- Create: `web-app/app/components/reviews/stars_component.html.erb`
- Test: `web-app/test/components/reviews/stars_component_test.rb`

**Interfaces:**
- Produces: `Reviews::StarsComponent.new(rating:, size: "size-4", label: nil)`. `rating` is a `Numeric` or `nil`; fractional values are legal (it renders averages as well as integer ratings). Tasks 3 and 5 render it.

> **Why clipping rather than counting.** The component draws five outline stars and lays a five-star filled copy over them, clipped to `rating / 5 × 100%`. An average of 3.96 clips at 79.2% — visibly "not quite four" — while an integer 4 clips at exactly 80%, landing on a star boundary. One component therefore serves both the average line and a per-review rating, and neither has to round a number into a lie.

> **The two star rows must render identical markup.** The clipped layer is positioned absolutely over the track, so its stars only line up if they are the same size and gap. The fill row also needs `w-max`, or its flex items shrink to fit the clipper and the stars slide leftward as the percentage drops.

- [ ] **Step 1: Vendor the icon**

Create `web-app/app/assets/svg/icons/lucide/outline/star.svg` with the canonical Lucide source (fetched from `raw.githubusercontent.com/lucide-icons/lucide/main/icons/star.svg`):

```svg
<svg
  xmlns="http://www.w3.org/2000/svg"
  width="24"
  height="24"
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="2"
  stroke-linecap="round"
  stroke-linejoin="round"
>
  <path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z" />
</svg>
```

The repo deliberately does **not** vendor all ~1,700 Lucide icons (see the README's curation policy). Add exactly this one file.

Then add a row to the table in `web-app/app/assets/svg/icons/README.md`, keeping it alphabetical among the existing rows:

```markdown
| `star` | `Reviews::StarsComponent` and `Reviews::HistogramComponent` |
```

- [ ] **Step 2: Generate the component**

```bash
bin/rails generate view_component:component Reviews::Stars rating
```

This writes the `.rb`, the `.html.erb`, and `test/components/reviews/stars_component_test.rb`. Steps 3–6 replace their contents.

- [ ] **Step 3: Write the failing test**

Replace `web-app/test/components/reviews/stars_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Reviews
  class StarsComponentTest < ViewComponent::TestCase
    test "clips the fill layer to the rating as a percentage of five" do
      render_inline(Reviews::StarsComponent.new(rating: 4))

      assert_selector "[data-testid='stars-fill'][style*='width: 80.0%']"
    end

    test "clips a fractional average proportionally rather than rounding it" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96))

      assert_selector "[data-testid='stars-fill'][style*='width: 79.2%']"
    end

    test "renders five stars in each of the two layers" do
      render_inline(Reviews::StarsComponent.new(rating: 5))

      assert_selector "[data-testid='stars-track'] svg", count: 5
      assert_selector "[data-testid='stars-fill'] svg", count: 5
    end

    test "fills the overlay stars and leaves the track stars outlined" do
      render_inline(Reviews::StarsComponent.new(rating: 5))

      assert_selector "[data-testid='stars-fill'] svg.fill-current", count: 5
      assert_no_selector "[data-testid='stars-track'] svg.fill-current"
    end

    test "exposes a single accessible label and hides the decorative layers" do
      render_inline(Reviews::StarsComponent.new(rating: 4.25))

      assert_selector "[role='img'][aria-label='4.3 out of 5 stars']"
      assert_selector "[data-testid='stars-track'][aria-hidden='true']"
      assert_selector "[data-testid='stars-fill'][aria-hidden='true']"
    end

    test "accepts a caller-supplied label" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96, label: "Average rating 4.0 out of 5"))

      assert_selector "[role='img'][aria-label='Average rating 4.0 out of 5']"
    end

    test "renders an empty track for a nil rating" do
      render_inline(Reviews::StarsComponent.new(rating: nil))

      assert_selector "[data-testid='stars-fill'][style*='width: 0.0%']"
      assert_selector "[role='img'][aria-label='Not yet rated']"
    end

    test "clamps a rating outside one to five" do
      render_inline(Reviews::StarsComponent.new(rating: 9))

      assert_selector "[data-testid='stars-fill'][style*='width: 100.0%']"
    end

    test "applies a caller-supplied size class to every star" do
      render_inline(Reviews::StarsComponent.new(rating: 2, size: "size-3"))

      assert_selector "svg.size-3", count: 10
      assert_no_selector "svg.size-4"
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/components/reviews/stars_component_test.rb`
Expected: FAIL — the generated component renders a placeholder, so every `assert_selector` misses.

- [ ] **Step 5: Write the component**

Replace `web-app/app/components/reviews/stars_component.rb`:

```ruby
# frozen_string_literal: true

module Reviews
  # A five-star rating drawn by clipping, not by counting: an outline track with a
  # filled copy laid over it and clipped to rating/5. A fractional average therefore
  # renders as a genuinely partial star instead of being rounded to a whole one, and
  # an integer rating clips exactly on a star boundary -- so one component serves both
  # the average on the summary line and the rating on a single review.
  #
  # Fill is a single colour throughout. The information is carried by how far the fill
  # extends and by the number printed beside it, never by hue.
  class StarsComponent < ViewComponent::Base
    MAX_RATING = 5

    def initialize(rating:, size: "size-4", label: nil)
      @rating = rating
      @size = size
      @label = label
    end

    private

    attr_reader :rating, :size

    # One decimal, so 79.2% survives instead of collapsing to 79%.
    def fill_percentage
      return 0.0 if rating.nil?

      (rating.to_f.clamp(0, MAX_RATING) / MAX_RATING * 100).round(1)
    end

    def label
      return @label if @label
      return "Not yet rated" if rating.nil?

      "#{rating.to_f.round(1)} out of #{MAX_RATING} stars"
    end

    def star_row(filled:)
      safe_join(Array.new(MAX_RATING) { star(filled: filled) })
    end

    # `shrink-0` matters: these are flex items inside a clipped, fixed-width overlay,
    # and without it they squeeze as the fill percentage falls.
    #
    # `fill-current` is a CSS declaration and so beats the `fill="none"` presentation
    # attribute baked into the vendored Lucide source.
    def star(filled:)
      classes = filled ? "#{size} shrink-0 fill-current" : "#{size} shrink-0"
      helpers.icon("star", library: "lucide", class: classes)
    end
  end
end
```

- [ ] **Step 6: Write the template**

Replace `web-app/app/components/reviews/stars_component.html.erb`:

```erb
<span class="relative inline-block align-middle leading-none" role="img" aria-label="<%= label %>">
  <span class="flex gap-px text-base-content/30" aria-hidden="true" data-testid="stars-track"><%= star_row(filled: false) %></span>
  <span class="absolute inset-y-0 start-0 overflow-hidden" style="width: <%= fill_percentage %>%" aria-hidden="true" data-testid="stars-fill">
    <span class="flex w-max gap-px text-warning"><%= star_row(filled: true) %></span>
  </span>
</span>
```

`w-max` on the inner row is load-bearing — see the interface note above.

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/components/reviews/stars_component_test.rb`
Expected: PASS, 9 runs.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb app/components/reviews test/components/reviews
git add app/assets/svg/icons app/components/reviews test/components/reviews
git commit -m "Add Reviews::StarsComponent and vendor the Lucide star"
```

---

### Task 2: `BodySanitizer.render` — the render-time pass

**Files:**
- Modify: `web-app/app/lib/services/reviews/body_sanitizer.rb`
- Test: `web-app/test/lib/services/reviews/body_sanitizer_test.rb` (append)

**Interfaces:**
- Consumes: `Services::Reviews::BodySanitizer::ALLOWED_TAGS`, `ALLOWED_ATTRIBUTES`, `SPOILER_CLASS` (increment 1).
- Produces: `Services::Reviews::BodySanitizer.render(body) -> ActiveSupport::SafeBuffer | nil`. Task 3 calls it.

> **Landmine — rendering must NOT re-run `.call`.** Stored bodies carry `<span class="review-spoiler">` wrappers, and `span` is deliberately absent from `ALLOWED_TAGS` so a user can never supply the class themselves. Feeding stored output back through `.call` therefore strips every wrapper and keeps its inner text — **118 production rows would print their spoilers in the clear**. `.render` needs its own allowlist, and Step 3 pins that failure mode with a test so nobody "simplifies" the two paths back into one.

> **Why the anchor hardening lives here and not in `.call`.** All 141,869 rows are already written, so anything added to the write path never reaches them. 119 rows contain an `<a>`, and this domain has ~156k indexed URLs — untrusted outbound links need `rel="nofollow ugc noopener"` at the moment they are rendered.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/services/reviews/body_sanitizer_test.rb`, inside the existing class:

```ruby
    test "render keeps the spoiler span the write path produced" do
      stored = Services::Reviews::BodySanitizer.call("<p>He <spoiler>dies</spoiler>.</p>")

      html = Services::Reviews::BodySanitizer.render(stored)

      assert_includes html, %(<span class="review-spoiler">dies</span>)
    end

    test "re-running call on a stored body would destroy the spoiler -- do not do it" do
      stored = Services::Reviews::BodySanitizer.call("<p>He <spoiler>dies</spoiler>.</p>")

      round_tripped = Services::Reviews::BodySanitizer.call(stored)

      refute_includes round_tripped, "review-spoiler"
      assert_includes round_tripped, "dies"
    end

    test "render strips a script even though the write path should have already" do
      html = Services::Reviews::BodySanitizer.render("<p>Hi</p><script>alert(1)</script>")

      refute_includes html, "script"
      assert_includes html, "Hi"
    end

    test "render strips an event handler smuggled onto an allowed tag" do
      html = Services::Reviews::BodySanitizer.render(%(<p onclick="alert(1)">Hi</p>))

      refute_includes html, "onclick"
    end

    test "render marks untrusted links nofollow, ugc, noopener and opens them away from the page" do
      html = Services::Reviews::BodySanitizer.render(%(<p><a href="https://example.com">link</a></p>))

      assert_includes html, %(rel="nofollow ugc noopener")
      assert_includes html, %(target="_blank")
    end

    test "render replaces any rel the body already carried" do
      html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.com" rel="dofollow">link</a>))

      refute_includes html, "dofollow"
      assert_includes html, %(rel="nofollow ugc noopener")
    end

    test "render returns an html_safe buffer" do
      html = Services::Reviews::BodySanitizer.render("<p>Hi</p>")

      assert_predicate html, :html_safe?
    end

    test "render returns nil for a nil or blank body" do
      assert_nil Services::Reviews::BodySanitizer.render(nil)
      assert_nil Services::Reviews::BodySanitizer.render("")
      assert_nil Services::Reviews::BodySanitizer.render("   ")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'render' for Services::Reviews::BodySanitizer`. The `re-running call` test should already PASS — it documents existing behaviour, and its job is to fail loudly if someone ever "fixes" `.call` to preserve spans.

- [ ] **Step 3: Implement `.render`**

In `web-app/app/lib/services/reviews/body_sanitizer.rb`, add the constants immediately after the existing ones:

```ruby
      # The render-time allowlist. It is NOT the write-time one, and the two must stay
      # in this file together so they cannot drift apart in review.
      #
      # `span` and `class` are absent from the write list on purpose -- that is what
      # stops a user supplying their own review-spoiler class. Stored bodies, however,
      # already contain the spans this class produced, so the render pass has to let
      # them through. Re-running .call on stored output instead would strip all 118
      # production spoiler wrappers and print their contents in the clear.
      RENDER_TAGS = (ALLOWED_TAGS + %w[span]).freeze
      RENDER_ATTRIBUTES = (ALLOWED_ATTRIBUTES + %w[class]).freeze
      LINK_REL = "nofollow ugc noopener"
```

Then add the class method beside `.call`:

```ruby
      # Sanitizes again on the way out -- the stored body was cleaned on write, but a
      # second pass costs one parse on a page that renders at most 37 reviews and means
      # no single bug can put markup on the page.
      def self.render(body)
        return nil if body.blank?

        new(body).render
      end
```

And the instance method, after `call`:

```ruby
      def render
        sanitized = sanitizer.sanitize(
          @body.to_s,
          tags: RENDER_TAGS,
          attributes: RENDER_ATTRIBUTES
        ).to_s

        fragment = Nokogiri::HTML5.fragment(sanitized)
        harden_links(fragment)
        # Safe to mark: everything in the buffer just came out of the sanitizer above.
        fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
      end
```

And the private helper, beside `convert_spoilers`:

```ruby
      # Review bodies are untrusted, and this domain has ~156k indexed URLs. Applied at
      # render rather than on write because all 141,869 migrated rows -- 119 of them
      # carrying an <a> -- were written before this existed.
      def harden_links(fragment)
        fragment.css("a").each do |node|
          node["rel"] = LINK_REL
          node["target"] = "_blank"
        end
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: PASS — the whole file, including every increment-1 test, still green.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/reviews test/lib/services/reviews
git add app/lib/services/reviews test/lib/services/reviews
git commit -m "Add BodySanitizer.render for the read surface"
```

---

### Task 3: `Reviews::ReviewComponent` — one written review

**Files:**
- Create: `web-app/app/components/reviews/review_component.rb`
- Create: `web-app/app/components/reviews/review_component.html.erb`
- Test: `web-app/test/components/reviews/review_component_test.rb`

**Interfaces:**
- Consumes: `Reviews::StarsComponent.new(rating:, size:, label:)` (Task 1) and `Services::Reviews::BodySanitizer.render(body)` (Task 2).
- Produces: `Reviews::ReviewComponent.new(review:)`, where `review` is a `Review`. Task 6 renders it in a loop.

> **No attribution, deliberately.** The row shows stars, relative time, an optional title, and the body — no author. That matches what the legacy book page renders today; only 56 of the 364 people who have written a review ever set a display name; and it means the row touches no association, so there is no per-row user load that could become an N+1.

- [ ] **Step 1: Generate the component**

```bash
bin/rails generate view_component:component Reviews::Review review
```

- [ ] **Step 2: Write the failing test**

Replace `web-app/test/components/reviews/review_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Reviews
  class ReviewComponentTest < ViewComponent::TestCase
    setup do
      @review = reviews(:regular_user_war_and_peace)
    end

    test "renders the rating as stars" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "[role='img'][aria-label='5.0 out of 5 stars']"
    end

    test "renders the title when there is one" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_text "A monumental achievement"
    end

    test "omits the title heading when there is none" do
      render_inline(Reviews::ReviewComponent.new(review: reviews(:editor_user_war_and_peace)))

      assert_no_selector "[data-testid='review-title']"
    end

    test "renders the stored body as markup rather than escaping it" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "[data-testid='review-body'] p", text: "Worth every one of its twelve hundred pages."
    end

    test "renders a machine-readable timestamp alongside the relative time" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "time[datetime='#{@review.created_at.iso8601}']"
      assert_text "ago"
    end

    test "keeps a spoiler span so the reveal controller has something to find" do
      @review.update!(body: "<p>He <spoiler>dies</spoiler>.</p>")

      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "span.review-spoiler", text: "dies"
    end

    test "does not attribute the review to its author" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      refute_includes rendered_content, @review.user.email
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/components/reviews/review_component_test.rb`
Expected: FAIL — the generated placeholder renders none of these.

- [ ] **Step 4: Write the component**

Replace `web-app/app/components/reviews/review_component.rb`:

```ruby
# frozen_string_literal: true

module Reviews
  # A single written review: stars, when it was written, an optional title, the body.
  #
  # No author. The legacy book page shows none either, only 56 of 364 reviewers ever
  # set a display name, and publishing names against 141,869 already-migrated rows was
  # never something their authors agreed to. It also keeps the row free of any
  # association, so a page of these loads no extra rows.
  class ReviewComponent < ViewComponent::Base
    def initialize(review:)
      @review = review
    end

    private

    attr_reader :review

    def body_html
      @body_html ||= Services::Reviews::BodySanitizer.render(review.body)
    end

    def written_at
      "#{time_ago_in_words(review.created_at)} ago"
    end

    def stars_label
      "Rated #{review.rating} out of 5"
    end
  end
end
```

- [ ] **Step 5: Write the template**

Replace `web-app/app/components/reviews/review_component.html.erb`:

```erb
<article class="border-t border-base-300 pt-4 first:border-t-0 first:pt-0" data-testid="review">
  <div class="flex flex-wrap items-center justify-between gap-2">
    <%= render Reviews::StarsComponent.new(rating: review.rating, label: stars_label) %>
    <time datetime="<%= review.created_at.iso8601 %>" class="text-sm text-base-content/60"><%= written_at %></time>
  </div>

  <% if review.title.present? %>
    <h3 class="mt-2 text-base font-semibold" data-testid="review-title"><%= review.title %></h3>
  <% end %>

  <% if body_html %>
    <div class="review-body mt-2 max-w-[68ch] leading-relaxed text-base-content/80" data-testid="review-body"><%= body_html %></div>
  <% end %>
</article>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/components/reviews/review_component_test.rb`
Expected: PASS, 7 runs.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/components/reviews test/components/reviews
git add app/components/reviews test/components/reviews
git commit -m "Add Reviews::ReviewComponent"
```

---

### Task 4: `Reviews::HistogramComponent`

**Files:**
- Create: `web-app/app/components/reviews/histogram_component.rb`
- Create: `web-app/app/components/reviews/histogram_component.html.erb`
- Test: `web-app/test/components/reviews/histogram_component_test.rb`

**Interfaces:**
- Consumes: `ReviewSummary#rating_counts -> {1 => Integer, …, 5 => Integer}` and `#rating_percentage(star) -> Float` (increment 1).
- Produces: `Reviews::HistogramComponent.new(summary:)`, where `summary` is a `ReviewSummary` or `nil`. Task 6 renders it.

- [ ] **Step 1: Generate the component**

```bash
bin/rails generate view_component:component Reviews::Histogram summary
```

- [ ] **Step 2: Write the failing test**

Replace `web-app/test/components/reviews/histogram_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Reviews
  class HistogramComponentTest < ViewComponent::TestCase
    setup do
      @summary = review_summaries(:war_and_peace)
    end

    test "renders one row per star, highest first" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      rows = page.all("[data-testid='histogram-row']").map { |row| row["data-rating"] }
      assert_equal %w[5 4 3 2 1], rows
    end

    test "sizes each bar by that rating's share of all ratings" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      # war_and_peace: 3 ratings -- one 5 (33.3%), two 4s (66.7%), none below.
      assert_selector "[data-testid='histogram-row'][data-rating='5'] [data-testid='histogram-bar'][style*='width: 33.3%']"
      assert_selector "[data-testid='histogram-row'][data-rating='4'] [data-testid='histogram-bar'][style*='width: 66.7%']"
      assert_selector "[data-testid='histogram-row'][data-rating='1'] [data-testid='histogram-bar'][style*='width: 0.0%']"
    end

    test "prints the count for each row" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      assert_selector "[data-testid='histogram-row'][data-rating='4'] [data-testid='histogram-count']", text: "2"
      assert_selector "[data-testid='histogram-row'][data-rating='3'] [data-testid='histogram-count']", text: "0"
    end

    test "labels each row for a screen reader" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      assert_selector "[data-testid='histogram-row'][data-rating='1']", text: "1 star"
      assert_selector "[data-testid='histogram-row'][data-rating='5']", text: "5 stars"
    end

    test "renders nothing without a summary" do
      render_inline(Reviews::HistogramComponent.new(summary: nil))

      assert_no_selector "[data-testid='rating-histogram']"
    end

    test "renders nothing when the summary has no ratings" do
      empty = ReviewSummary.create!(reviewable: books_books(:got))

      render_inline(Reviews::HistogramComponent.new(summary: empty))

      assert_no_selector "[data-testid='rating-histogram']"
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/components/reviews/histogram_component_test.rb`
Expected: FAIL.

- [ ] **Step 4: Write the component**

Replace `web-app/app/components/reviews/histogram_component.rb`:

```ruby
# frozen_string_literal: true

module Reviews
  # The per-star breakdown behind an average. Bars are all one colour -- the length of
  # the bar and the count beside it carry the meaning, never the hue.
  class HistogramComponent < ViewComponent::Base
    def initialize(summary:)
      @summary = summary
    end

    # Nil for the 72,659 books nobody has rated; zero-count rows exist too, because a
    # summary survives the deletion of its last review.
    def render?
      summary.present? && summary.ratings_count.positive?
    end

    private

    attr_reader :summary

    def rows
      5.downto(1).map do |star|
        {
          star: star,
          count: summary.rating_counts.fetch(star),
          percentage: summary.rating_percentage(star).round(1)
        }
      end
    end
  end
end
```

- [ ] **Step 5: Write the template**

Replace `web-app/app/components/reviews/histogram_component.html.erb`:

```erb
<ul class="space-y-1.5" data-testid="rating-histogram">
  <% rows.each do |row| %>
    <li class="flex items-center gap-3 text-sm" data-testid="histogram-row" data-rating="<%= row[:star] %>">
      <span class="flex w-14 shrink-0 items-center gap-1 tabular-nums text-base-content/70">
        <%= row[:star] %>
        <%= helpers.icon "star", library: "lucide", class: "size-3 shrink-0 fill-current text-warning" %>
        <span class="sr-only"><%= (row[:star] == 1) ? "star" : "stars" %></span>
      </span>
      <span class="h-2 flex-1 overflow-hidden rounded-full bg-base-300">
        <span class="block h-full bg-primary" style="width: <%= row[:percentage] %>%" data-testid="histogram-bar"></span>
      </span>
      <span class="w-12 shrink-0 text-end tabular-nums text-base-content/70" data-testid="histogram-count"><%= row[:count] %></span>
    </li>
  <% end %>
</ul>
```

`bg-primary` on `bg-base-300` is a deep blue on a light warm grey — separated by lightness, not hue, so the bars stay readable regardless of colour vision.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/components/reviews/histogram_component_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/components/reviews test/components/reviews
git add app/components/reviews test/components/reviews
git commit -m "Add Reviews::HistogramComponent"
```

---

### Task 5: `ReviewSummary#rounded_average_rating` and `Reviews::SummaryLineComponent`

**Files:**
- Modify: `web-app/app/models/review_summary.rb`
- Create: `web-app/app/components/reviews/summary_line_component.rb`
- Create: `web-app/app/components/reviews/summary_line_component.html.erb`
- Test: `web-app/test/models/review_summary_test.rb` (append)
- Test: `web-app/test/components/reviews/summary_line_component_test.rb`

**Interfaces:**
- Consumes: `Reviews::StarsComponent` (Task 1); `ReviewSummary#average_rating` (increment 1).
- Produces: `ReviewSummary#rounded_average_rating -> Float | nil`, and `Reviews::SummaryLineComponent.new(summary:)`. Task 6 uses `rounded_average_rating`; Task 8 renders the component.

> **One rounding site, not two.** Both this component and the card print the average. Rounding on the model keeps them from drifting — and `Float#to_s` on a value already rounded to one decimal always keeps the decimal, so `4.0` renders as `"4.0"` and never as `"4"`.

- [ ] **Step 1: Write the failing model test**

Append to `web-app/test/models/review_summary_test.rb`, inside the existing class:

```ruby
  test "rounds the average to one decimal place" do
    summary = review_summaries(:war_and_peace) # 3 ratings, sum 13

    assert_in_delta 4.3, summary.rounded_average_rating, 0.001
  end

  test "keeps a whole average at one decimal place when printed" do
    summary = review_summaries(:crime_and_punishment) # 1 rating, sum 3

    assert_equal "3.0", summary.rounded_average_rating.to_s
  end

  test "has no rounded average without ratings" do
    assert_nil ReviewSummary.new(reviewable: books_books(:got)).rounded_average_rating
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/review_summary_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'rounded_average_rating'`.

- [ ] **Step 3: Add the method**

In `web-app/app/models/review_summary.rb`, immediately after `average_rating`:

```ruby
  # The single rounding site for the average, so the summary line and the reviews card
  # can never print different numbers for the same book.
  def rounded_average_rating
    average_rating&.round(1)
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/models/review_summary_test.rb`
Expected: PASS.

- [ ] **Step 5: Generate the component**

```bash
bin/rails generate view_component:component Reviews::SummaryLine summary
```

- [ ] **Step 6: Write the failing component test**

Replace `web-app/test/components/reviews/summary_line_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Reviews
  class SummaryLineComponentTest < ViewComponent::TestCase
    test "prints the average, the rating count and the review count" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_text "4.3"
      assert_text "3 ratings"
      assert_text "2 reviews"
    end

    test "omits the review count when nothing is written" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:crime_and_punishment)))

      assert_text "1 rating"
      assert_no_text "review"
    end

    test "labels the stars with the average" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "[role='img'][aria-label='Average rating 4.3 out of 5']"
    end

    test "links down to the reviews card" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "a[href='#ratings-reviews'][data-testid='review-summary-line']"
    end

    test "renders nothing without a summary" do
      render_inline(Reviews::SummaryLineComponent.new(summary: nil))

      assert_no_selector "[data-testid='review-summary-line']"
    end

    test "renders nothing when the summary has no ratings" do
      empty = ReviewSummary.create!(reviewable: books_books(:got))

      render_inline(Reviews::SummaryLineComponent.new(summary: empty))

      assert_no_selector "[data-testid='review-summary-line']"
    end
  end
end
```

- [ ] **Step 7: Run it to verify it fails**

Run: `bin/rails test test/components/reviews/summary_line_component_test.rb`
Expected: FAIL.

- [ ] **Step 8: Write the component**

Replace `web-app/app/components/reviews/summary_line_component.rb`:

```ruby
# frozen_string_literal: true

module Reviews
  # The compact rating line that sits under a book's rank. The whole line is the link
  # down to the reviews card, so the number a reader notices is also the way to the
  # detail behind it.
  class SummaryLineComponent < ViewComponent::Base
    ANCHOR = "ratings-reviews"

    def initialize(summary:)
      @summary = summary
    end

    def render?
      summary.present? && summary.ratings_count.positive?
    end

    private

    attr_reader :summary

    def stars_label
      "Average rating #{summary.rounded_average_rating} out of 5"
    end
  end
end
```

- [ ] **Step 9: Write the template**

Replace `web-app/app/components/reviews/summary_line_component.html.erb`:

```erb
<a href="#<%= ANCHOR %>" class="mt-3 inline-flex flex-wrap items-center gap-2 link link-hover" data-testid="review-summary-line">
  <%= render Reviews::StarsComponent.new(rating: summary.average_rating, label: stars_label) %>
  <span class="font-semibold tabular-nums"><%= summary.rounded_average_rating %></span>
  <span class="text-base-content/70">
    · <%= pluralize(summary.ratings_count, "rating") %><% if summary.text_reviews_count.positive? %> · <%= pluralize(summary.text_reviews_count, "review") %><% end %>
  </span>
</a>
```

- [ ] **Step 10: Run it to verify it passes**

Run: `bin/rails test test/components/reviews/summary_line_component_test.rb test/models/review_summary_test.rb`
Expected: PASS.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb app/models/review_summary.rb app/components/reviews test/components/reviews test/models/review_summary_test.rb
git add app/models/review_summary.rb app/components/reviews test/components/reviews test/models/review_summary_test.rb
git commit -m "Add Reviews::SummaryLineComponent and a single rounding site for the average"
```

---

### Task 6: `Reviews::CardComponent`

**Files:**
- Create: `web-app/app/components/reviews/card_component.rb`
- Create: `web-app/app/components/reviews/card_component.html.erb`
- Test: `web-app/test/components/reviews/card_component_test.rb`

**Interfaces:**
- Consumes: `Reviews::HistogramComponent.new(summary:)` (Task 4), `Reviews::ReviewComponent.new(review:)` (Task 3), `ReviewSummary#rounded_average_rating` (Task 5).
- Produces: `Reviews::CardComponent.new(summary:, reviews:)`, where `reviews` is an ordered enumerable of `Review`. Task 7's Stimulus controller mounts on this component's root element; Task 8 renders it.

> **The card is where the spoiler controller mounts, and that is not incidental.** Bodies are sanitized on the way in, and the sanitizer strips `data-*`, so a spoiler span can never carry its own `data-action`. The controller therefore lives on the card and finds spoilers by delegation.

- [ ] **Step 1: Generate the component**

```bash
bin/rails generate view_component:component Reviews::Card summary reviews
```

- [ ] **Step 2: Write the failing test**

Replace `web-app/test/components/reviews/card_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Reviews
  class CardComponentTest < ViewComponent::TestCase
    setup do
      @book = books_books(:war_and_peace)
      @summary = review_summaries(:war_and_peace)
      @reviews = @book.reviews.with_body.recent
    end

    test "anchors at the id the summary line links to" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "#ratings-reviews"
    end

    test "mounts the spoiler controller on the card, not on the spans" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "#ratings-reviews[data-controller='reviews--spoiler']"
      assert_selector "#ratings-reviews[data-action*='click->reviews--spoiler#reveal']"
      assert_selector "#ratings-reviews[data-action*='keydown->reviews--spoiler#revealOnKey']"
    end

    test "renders the histogram" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "[data-testid='rating-histogram']"
    end

    test "renders one block per written review" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "[data-testid='review']", count: 2
    end

    test "renders the reviews in the order it was given them" do
      # An explicit array, not the scope: both fixture reviews share a created_at, so
      # asserting that a sorted list is sorted would pass without proving anything.
      ordered = [reviews(:editor_user_war_and_peace), reviews(:regular_user_war_and_peace)]

      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: ordered))

      bodies = page.all("[data-testid='review-body']").map(&:text)
      assert_match(/Skip the philosophy/, bodies.first)
      assert_match(/Worth every one/, bodies.last)
    end

    test "says so when a book is rated but nobody has written anything" do
      render_inline(Reviews::CardComponent.new(
        summary: review_summaries(:crime_and_punishment),
        reviews: Review.none
      ))

      assert_selector "#ratings-reviews"
      assert_text "No written reviews yet"
      assert_no_selector "[data-testid='review']"
    end

    test "prints the average and the rating count in the header" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_text "4.3"
      assert_text "3 ratings"
    end

    test "renders nothing at all for a book with no ratings" do
      empty = ReviewSummary.create!(reviewable: books_books(:got))

      render_inline(Reviews::CardComponent.new(summary: empty, reviews: Review.none))

      assert_no_selector "#ratings-reviews"
    end

    test "renders nothing without a summary" do
      render_inline(Reviews::CardComponent.new(summary: nil, reviews: Review.none))

      assert_no_selector "#ratings-reviews"
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/components/reviews/card_component_test.rb`
Expected: FAIL.

- [ ] **Step 4: Write the component**

Replace `web-app/app/components/reviews/card_component.rb`:

```ruby
# frozen_string_literal: true

module Reviews
  # The Ratings & Reviews card at the foot of a book page: the per-star histogram, then
  # every written review in the order the caller supplied.
  #
  # Unpaginated on purpose. The most-reviewed book in the corpus has 37 written reviews
  # and none has more than 50; paging would be machinery for a case that does not exist,
  # and it would mint crawlable URLs that today would never have a page 2.
  class CardComponent < ViewComponent::Base
    # One definition of the anchor, shared with the line that links to it.
    ANCHOR = Reviews::SummaryLineComponent::ANCHOR

    def initialize(summary:, reviews:)
      @summary = summary
      @reviews = reviews
    end

    def render?
      summary.present? && summary.ratings_count.positive?
    end

    private

    attr_reader :summary, :reviews
  end
end
```

- [ ] **Step 5: Write the template**

Replace `web-app/app/components/reviews/card_component.html.erb`:

```erb
<div class="card bg-base-100 shadow-md scroll-mt-8"
     id="<%= ANCHOR %>"
     data-controller="reviews--spoiler"
     data-action="click->reviews--spoiler#reveal keydown->reviews--spoiler#revealOnKey">
  <div class="card-body">
    <h2 class="card-title text-xl">Ratings &amp; Reviews</h2>
    <p class="text-sm text-base-content/70">
      <span class="font-semibold tabular-nums"><%= summary.rounded_average_rating %></span>
      out of 5 · <%= pluralize(summary.ratings_count, "rating") %>
    </p>

    <div class="mt-4">
      <%= render Reviews::HistogramComponent.new(summary: summary) %>
    </div>

    <% if reviews.any? %>
      <div class="mt-6 space-y-4">
        <% reviews.each do |review| %>
          <%= render Reviews::ReviewComponent.new(review: review) %>
        <% end %>
      </div>
    <% else %>
      <p class="mt-6 text-base-content/70">No written reviews yet.</p>
    <% end %>
  </div>
</div>
```

- [ ] **Step 6: Run it to verify it passes**

Run: `bin/rails test test/components/reviews/card_component_test.rb`
Expected: PASS, 9 runs.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/components/reviews test/components/reviews
git add app/components/reviews test/components/reviews
git commit -m "Add Reviews::CardComponent"
```

---

### Task 7: Spoiler styling and the reveal controller

**Files:**
- Create: `web-app/app/assets/stylesheets/books/reviews.css`
- Modify: `web-app/app/assets/stylesheets/books/application.css` (add the import beside `paging.css`)
- Create: `web-app/app/javascript/controllers/reviews/spoiler_controller.js`
- Modify: `web-app/app/javascript/controllers/index.js` (regenerated, not hand-edited)

**Interfaces:**
- Consumes: the `.review-spoiler` spans `Services::Reviews::BodySanitizer` writes, and the `data-controller="reviews--spoiler"` root from Task 6.
- Produces: no Ruby interface. The controller adds `.review-spoiler--revealed` on click or Enter/Space.

> **The controller cannot use targets, and cannot be mounted on the spans.** Review bodies pass through `SafeListSanitizer` with an allowlist of `href title class`, so `data-action`, `data-reviews--spoiler-target` and every other `data-*` attribute is stripped from anything inside a body. Delegation from the card is the only wiring that survives the sanitizer.

> **CSS lives in the books stylesheet only.** There is no shared domain stylesheet — each domain builds its own bundle, which is why `paging.css` is duplicated per domain. Books is the only domain rendering reviews today. When music or games adopt them, they need their own copy of this import.

- [ ] **Step 1: Write the stylesheet**

Create `web-app/app/assets/stylesheets/books/reviews.css`, following `paging.css`'s plain-rules-with-`@apply` style:

```css
/* Spoiler spans are written by Services::Reviews::BodySanitizer at save time, so
   Tailwind never sees the class name in a source file -- these rules are hand-written
   rather than generated. 118 migrated review bodies depend on them. */
.review-spoiler {
  @apply cursor-pointer rounded select-none;
  filter: blur(0.35rem);
  transition: filter 150ms ease-in-out;
}

.review-spoiler:focus-visible {
  outline: 2px solid var(--color-primary);
  outline-offset: 3px;
}

.review-spoiler--revealed {
  @apply cursor-auto select-auto;
  filter: none;
}

/* Review bodies are sanitized HTML, so Tailwind's preflight has already flattened the
   <p>, <a> and <blockquote> tags they contain. */
.review-body p + p {
  @apply mt-3;
}

.review-body a {
  @apply link;
}

.review-body blockquote {
  @apply my-3 italic;
  border-inline-start: 3px solid var(--color-base-300);
  padding-inline-start: 0.75rem;
}
```

- [ ] **Step 2: Import it**

In `web-app/app/assets/stylesheets/books/application.css`, add the import directly beneath the existing paging import (line 2):

```css
@import "./paging.css";
@import "./reviews.css";
```

- [ ] **Step 3: Write the Stimulus controller**

Create `web-app/app/javascript/controllers/reviews/spoiler_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Reveals a blurred spoiler inside a review body.
//
// Mounted on the reviews card and delegating downward -- never on the spans. Review
// bodies go through SafeListSanitizer with an allowlist of href/title/class, so a span
// inside a body can never carry its own data-action or Stimulus target. connect() also
// has to add the keyboard affordances for the same reason: the sanitizer strips
// tabindex and role too.
export default class extends Controller {
  static SELECTOR = ".review-spoiler"

  connect() {
    this.element.querySelectorAll(this.constructor.SELECTOR).forEach((spoiler) => {
      spoiler.setAttribute("tabindex", "0")
      spoiler.setAttribute("role", "button")
      spoiler.setAttribute("aria-expanded", "false")
      spoiler.setAttribute("aria-label", "Show spoiler")
    })
  }

  reveal(event) {
    const spoiler = event.target.closest(this.constructor.SELECTOR)
    if (!spoiler) return

    this.showSpoiler(spoiler)
  }

  revealOnKey(event) {
    if (event.key !== "Enter" && event.key !== " ") return

    const spoiler = event.target.closest(this.constructor.SELECTOR)
    if (!spoiler) return

    event.preventDefault()
    this.showSpoiler(spoiler)
  }

  showSpoiler(spoiler) {
    spoiler.classList.add("review-spoiler--revealed")
    spoiler.setAttribute("aria-expanded", "true")
    spoiler.removeAttribute("aria-label")
    spoiler.removeAttribute("role")
  }
}
```

- [ ] **Step 4: Regenerate the Stimulus manifest**

```bash
bin/rails stimulus:manifest:update
```

`app/javascript/controllers/index.js` is auto-generated — never hand-edit it. Confirm the diff adds exactly:

```js
import Reviews__SpoilerController from "./reviews/spoiler_controller"
application.register("reviews--spoiler", Reviews__SpoilerController)
```

The books layout loads `application.js`, which imports `./controllers`, so registration is all that is needed — `books.js` is not involved.

- [ ] **Step 5: Build the assets**

```bash
yarn build:all
```

Expected: no errors. Rollup does not transpile, so keep the controller to syntax modern browsers accept directly (this one does — no private `#` fields).

- [ ] **Step 6: Commit**

```bash
git add app/assets/stylesheets/books app/javascript/controllers app/assets/builds
git commit -m "Add spoiler styling and the reveal controller"
```

Note: `app/assets/builds/` is committed in this repo — include the rebuilt bundles.

---

### Task 8: Wire the surface into the book page

**Files:**
- Modify: `web-app/app/controllers/books/books_controller.rb`
- Modify: `web-app/app/views/books/books/show.html.erb`
- Test: `web-app/test/controllers/books/books_controller_test.rb` (append)

**Interfaces:**
- Consumes: `Reviews::SummaryLineComponent.new(summary:)` (Task 5) and `Reviews::CardComponent.new(summary:, reviews:)` (Task 6).
- Produces: `@review_summary` and `@reviews` assigns on `Books::BooksController#show`.

> **Two queries, both indexed, and neither may grow with the review count.** `review_summaries` has a unique index on `(reviewable_type, reviewable_id)`; `reviews` has the partial index `index_reviews_on_reviewable_with_body`. Step 4's test proves the count does not change when the number of reviews does — that is the N+1 guard, and it is written as a comparison rather than a hardcoded number so unrelated controller changes do not churn it.

- [ ] **Step 1: Write the failing controller tests**

Append to `web-app/test/controllers/books/books_controller_test.rb`, inside `Books::BooksControllerTest`:

```ruby
    test "assigns the review summary and only the written reviews" do
      get "/book/#{@book.slug}"

      assert_response :success
      assert_equal review_summaries(:war_and_peace), @controller.view_assigns["review_summary"]
      assert_equal 2, @controller.view_assigns["reviews"].size
      assert @controller.view_assigns["reviews"].all? { |review| review.body.present? }
    end

    test "orders the reviews newest first" do
      older = Review.create!(user: users(:password_user), reviewable: @book, rating: 2, body: "<p>Older.</p>")
      older.update_columns(created_at: 5.years.ago)

      get "/book/#{@book.slug}"

      assert_equal older.id, @controller.view_assigns["reviews"].last.id
    end

    test "renders the summary line and the reviews card for a rated book" do
      get "/book/#{@book.slug}"

      assert_select "[data-testid='review-summary-line']"
      assert_select "#ratings-reviews"
      assert_select "[data-testid='review']", 2
    end

    test "renders the card without a review list for a book rated but not reviewed" do
      book = books_books(:crime_and_punishment)

      get "/book/#{book.slug}"

      assert_select "#ratings-reviews"
      assert_select "[data-testid='review']", 0
    end

    test "renders no rating surface at all for an unrated book" do
      book = books_books(:got)

      get "/book/#{book.slug}"

      assert_response :success
      assert_select "[data-testid='review-summary-line']", 0
      assert_select "#ratings-reviews", 0
    end

    test "renders review bodies as markup rather than escaping them" do
      get "/book/#{@book.slug}"

      assert_select "[data-testid='review-body'] p", text: "Worth every one of its twelve hundred pages."
    end

    # The N+1 guard. Written as a comparison rather than a fixed count so that an
    # unrelated query added to #show does not fail it -- what must hold is that the
    # number of queries is independent of the number of reviews rendered.
    test "renders any number of reviews with the same number of queries" do
      book = books_books(:crime_and_punishment)
      Review.create!(user: users(:editor_user), reviewable: book, rating: 5, body: "<p>One.</p>")
      baseline = count_queries { get "/book/#{book.slug}" }

      Review.create!(user: users(:admin_user), reviewable: book, rating: 4, body: "<p>Two.</p>")
      Review.create!(user: users(:password_user), reviewable: book, rating: 3, body: "<p>Three.</p>")
      with_more = count_queries { get "/book/#{book.slug}" }

      assert_equal baseline, with_more,
        "rendering reviews must not issue a query per review"
    end

    # Deliberately not declared `private`. Minitest only collects public `test_`
    # methods, so a `private` keyword here would silently stop every test defined
    # after it in the file from running.
    def count_queries
      count = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA"
        next if payload[:sql].start_with?("BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE")

        count += 1
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: FAIL — `review_summary` and `reviews` are not assigned and nothing renders.

- [ ] **Step 3: Wire the controller**

In `web-app/app/controllers/books/books_controller.rb#show`, add `:review_summary` to the existing preloads and set the two assigns at the end of the action:

```ruby
    @book = Books::Book
      .includes(:categories, :descriptions, :review_summary, {book_authors: :author})
      .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
      .find_by!(slug: params[:slug])
```

and, after `@list_items`:

```ruby
    # Preloaded above, so this is not a query. Nil for the 72,659 books nobody has
    # rated -- both review components render nothing in that case.
    @review_summary = @book.review_summary

    # Written reviews only, newest first, unpaginated: the most-reviewed book in the
    # corpus has 37. Served by index_reviews_on_reviewable_with_body. No association is
    # preloaded because a review row renders no author.
    @reviews = @book.reviews.with_body.recent.to_a
```

- [ ] **Step 4: Wire the view**

In `web-app/app/views/books/books/show.html.erb`, insert the summary line immediately after the `@ranked_item` paragraph and before the `<div class="mt-4">` holding the user-list widget:

```erb
      <%= render Reviews::SummaryLineComponent.new(summary: @review_summary) %>
```

Then append the card as the last child of the `lg:col-span-2` column — after the `@list_items` card's closing `<% end %>`, still inside the column div:

```erb
    <%= render Reviews::CardComponent.new(summary: @review_summary, reviews: @reviews) %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: PASS — every pre-existing test in the file still green.

- [ ] **Step 6: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

Expected: no failures, no offenses. Increment 1's `SummaryRecalculator` tests and increment 2's migrator tests must be untouched.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/books/books_controller.rb app/views/books/books/show.html.erb test/controllers/books/books_controller_test.rb
git commit -m "Show ratings and written reviews on the book page"
```

---

### Task 9: End-to-end coverage and verification against real data

**Files:**
- Create: `web-app/e2e/tests/books/reviews.spec.ts`

**Interfaces:**
- Consumes: the rendered book page from Task 8, against the **development** database, which holds the full migrated corpus.

> **Playwright here runs against dev data, as the existing books specs do** (`book-detail.spec.ts` navigates to `/books/1`). Two books are pinned by slug because their content is what makes the assertions meaningful: `the-great-gatsby` is the most-reviewed book in the corpus (450 ratings, 37 written), and `room-for-murder` is book 17,447, one of the 118 rows carrying a spoiler.

- [ ] **Step 1: Write the spec**

Create `web-app/e2e/tests/books/reviews.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

// the-great-gatsby is the most-reviewed book in the migrated corpus: 450 ratings and
// 37 written reviews as of the 2026-08-10 production migration.
const REVIEWED_BOOK = '/book/the-great-gatsby';

// One of the 118 migrated bodies containing a <spoiler> tag.
const SPOILER_BOOK = '/book/room-for-murder';

test.describe('Book page ratings and reviews', () => {
  test('a rated book shows the summary line and the reviews card', async ({ page }) => {
    await page.goto(REVIEWED_BOOK);

    const summaryLine = page.getByTestId('review-summary-line');
    await expect(summaryLine).toBeVisible();
    await expect(summaryLine).toContainText('ratings');

    await expect(page.locator('#ratings-reviews')).toBeVisible();
    await expect(page.getByTestId('rating-histogram').getByTestId('histogram-row')).toHaveCount(5);
    expect(await page.getByTestId('review').count()).toBeGreaterThan(1);
  });

  test('the summary line jumps to the reviews card', async ({ page }) => {
    await page.goto(REVIEWED_BOOK);

    await page.getByTestId('review-summary-line').click();

    await expect(page).toHaveURL(/#ratings-reviews$/);
    await expect(page.locator('#ratings-reviews')).toBeInViewport();
  });

  test('reviews are listed newest first', async ({ page }) => {
    await page.goto(REVIEWED_BOOK);

    const stamps = await page.getByTestId('review').locator('time').evaluateAll(
      (nodes) => nodes.map((node) => node.getAttribute('datetime') ?? '')
    );

    expect(stamps.length).toBeGreaterThan(1);
    expect(stamps).toEqual([...stamps].sort().reverse());
  });

  test('a spoiler stays blurred until it is clicked', async ({ page }) => {
    await page.goto(SPOILER_BOOK);

    const spoiler = page.locator('.review-spoiler').first();
    await expect(spoiler).toBeVisible();
    await expect(spoiler).toHaveAttribute('role', 'button');
    await expect(spoiler).not.toHaveClass(/review-spoiler--revealed/);

    await spoiler.click();

    await expect(spoiler).toHaveClass(/review-spoiler--revealed/);
    await expect(spoiler).toHaveAttribute('aria-expanded', 'true');
  });

  test('a spoiler can be revealed from the keyboard', async ({ page }) => {
    await page.goto(SPOILER_BOOK);

    const spoiler = page.locator('.review-spoiler').first();
    await spoiler.focus();
    await page.keyboard.press('Enter');

    await expect(spoiler).toHaveClass(/review-spoiler--revealed/);
  });

  test('an unrated book shows no rating surface', async ({ page }) => {
    // Book 200, verified to have no review_summary row. 72,659 of the 126,289 books
    // have never been rated, so this is the common case, not an edge case.
    await page.goto('/book/nightmare-abbey');

    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await expect(page.getByTestId('review-summary-line')).toHaveCount(0);
    await expect(page.locator('#ratings-reviews')).toHaveCount(0);
  });
});
```

- [ ] **Step 2: Start the dev server and run the spec**

`bin/dev` self-terminates in a non-interactive shell, so start the pieces directly:

```bash
yarn build:all
bin/rails server
```

In a second shell:

```bash
yarn test:e2e e2e/tests/books/reviews.spec.ts
```

Expected: 6 passed. If the spoiler spec cannot find `.review-spoiler`, confirm `yarn build:all` actually rebuilt `app/assets/builds/books.css` — the blur rule is new CSS, and a stale bundle is the usual cause.

- [ ] **Step 3: Eyeball the three states in a browser**

Visit each and confirm the page reads correctly:

| URL | Expect |
|---|---|
| `/book/the-great-gatsby` | summary line reading `4.0 · 450 ratings · 37 reviews`, histogram peaking at 4★ (183), 37 review blocks |
| `/book/room-for-murder` | at least one blurred span that sharpens on click |
| any book with no ratings | no summary line, no card, page otherwise unchanged |

- [ ] **Step 4: Full verification**

```bash
bin/rails test
bundle exec standardrb
```

Expected: green and clean. Record the actual run/assertion counts in the commit message rather than asserting "all tests pass" from memory.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/reviews.spec.ts
git commit -m "Add E2E coverage for the book page reviews surface"
```

---

## Deferred to later increments — do not build these here

- **The write flow** (rating widget, modal, `ReviewStateController`, `ReviewsController`, `ReviewPolicy`) is increment 4. It is where the CSRF-token-from-an-uncached-endpoint requirement lives.
- **`/my/reviews`**, the `/reviews` 301s, and the admin index are increment 5.
- **`docs/features/reviews.md`.** Increments 1 and 2 shipped no feature doc, matching how the saved-searches initiative wrote its doc in its final increment. Write it in increment 5, covering the whole feature at once.
- **Ratings on the ranked grid and list cards** are a spec non-goal — that is the N+1 shape the spec explicitly excludes.
- **Music and games reviews.** The components are namespaced globally so they are cheap to adopt, but only `Books::Book` is wired up, and only the books stylesheet carries `reviews.css`.

## Cache note for whoever deploys this

The book page is edge-cached for 24 hours. The migrated corpus is static, so nothing goes stale today — but once increment 4 lets people write, a new review will not appear on a cached page until the entry expires. That is expected, and it is why increment 4's widget hydrates client-side rather than being server-rendered.
