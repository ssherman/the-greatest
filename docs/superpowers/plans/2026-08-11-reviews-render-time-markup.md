# Review Bodies: Render-Time Markup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Services::Reviews::BodySanitizer.call` idempotent by moving every markup transformation to render time, so the round-trip bug class that produced three production-class defects in one increment becomes unrepresentable.

**Architecture:** `call` sanitizes and never transforms. Spoilers are stored as `||…||` and paragraphs as plain newlines — exactly what the author typed — and both become markup in `render`. That retires `for_editing`, `scrub_classes`, the write-time paragraph conversion, and `Review`'s pre-sanitize length machinery. 119 stored rows carrying a legacy spoiler span convert via a **Rails migration**, which the container entrypoint runs before the server serves traffic.

**Tech Stack:** Rails 8.1.3.1, Nokogiri (`Nokogiri::HTML5.fragment`), `Rails::HTML5::SafeListSanitizer`, Minitest + fixtures + Mocha, Playwright, Standard (standardrb).

**Spec:** `docs/superpowers/specs/2026-08-09-books-reviews-design.md` — the `### Body handling` section, revised 2026-08-11 (commit `77ccde7a`).
**Builds on:** increments 1–4 (PRs #213, #215, #216, #218), all merged and in production.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Working branch is `books-reviews-render-time-markup`, cut from `main` in the main checkout (no worktree).
- Lint with `bundle exec standardrb`. **Not** `bin/rubocop`. Never run brakeman.
- **Never run a destructive database command.** No `db:drop`, `db:reset`, `db:schema:load`, no bulk `delete_all`/`destroy_all`, nothing that truncates. The development database holds books data existing nowhere else. Read fixture YAML directly to inspect it.
- **`BodySanitizer.call` is on the write path for every review and its output is what gets STORED.** 141,869 rows already exist. Treat every change to it as high risk and prove the behaviours its header documents are unchanged.
- **Never make a real network call to Cloudflare** — `web-app/.env` holds a real API token and books zone id.
- **Do not start a dev server or run the Playwright suite** unless a task says to. A concurrent E2E run writes to the development database.
- Spoiler syntax is `||…||`. Measured: **0 existing bodies contain `||`; 7 contain `>!`**.
- Markup generation at render must walk **text nodes only**. An attribute value is not a text node, so `<a href="||evil||">` can never receive a spliced span. This is the same discipline the sanitizer's header already insists on.

## The ordering constraint that decides Task 5's form

`web-app/bin/docker-entrypoint` runs `./bin/rails db:prepare` **before** `rails server` starts, so a Rails migration completes before the new code serves a single request. That is the only ordering with no exposure window:

| If the conversion were… | What happens |
|---|---|
| a rake task run *before* merging | the 119 rows show `||secret||` as literal text under the current render path |
| a rake task run *after* deploying | the new render allowlist drops `span`, so those 119 spoilers render in the clear |
| **a Rails migration** | runs at container start, before traffic — **no window in either direction** |

So Task 5 is a migration, not a rake task, and Task 6 (which removes `span` from the render allowlist) depends on it. They ship in the same PR.

## Current state this plan dismantles

| Thing | Where | Fate |
|---|---|---|
| `convert_spoilers` (write) | `body_sanitizer.rb:192` | replaced by render-time marker conversion |
| `paragraphize` called from `call` | `body_sanitizer.rb:120` | moves to `render` |
| `for_editing` + `restore_spoiler_tags` + `restore_paragraphs` + `paragraph_source` | `body_sanitizer.rb:106,153,206,237,252` | **deleted** |
| `scrub_classes` | `body_sanitizer.rb:265` | **deleted** |
| `span` in `RENDER_TAGS`, `class` in `RENDER_ATTRIBUTES` | `body_sanitizer.rb:66,77` | **deleted** |
| `@body_length_before_sanitizing`, `@sanitized_body`, `validate_body_length` | `review.rb:48,67,120` | replaced by a plain length validation |
| `BodySanitizer.for_editing` call | `review_state_controller.rb:52` | returns `review.body` directly |

---

### Task 1: Render-time markup — paragraphs and spoiler markers

**Files:**
- Modify: `web-app/app/lib/services/reviews/body_sanitizer.rb`
- Test: `web-app/test/lib/services/reviews/body_sanitizer_test.rb` (append)

**Interfaces:**
- Produces: `BodySanitizer.render` now converts `||…||` to `<span class="review-spoiler">` and blank-line-separated text to paragraphs. Tasks 2, 5 and 6 depend on this being in place first.

> **This task changes only `render`. Leave `call` exactly as it is** — it still converts `<spoiler>` and still paragraphizes on write. The suite must stay green at every task boundary, and decoupling the read path first is what makes that possible.

> **Text nodes only.** Build the replacement by escaping the text either side of each marker pair and emitting the span between them, then replace the text node with the parsed result. Never `gsub` over serialized markup — that is the exact failure this file's header documents, and it applies identically in this direction.

> **Top-level text nodes matter most.** A short review with no newlines is not paragraphized, so its entire body is a bare top-level text node. Verify your node selection actually reaches those, not just nested ones — an implementation that only walks descendants of elements silently does nothing for the commonest case.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/services/reviews/body_sanitizer_test.rb`, inside the existing class:

```ruby
    test "render converts a spoiler marker into a spoiler span" do
      html = Services::Reviews::BodySanitizer.render("He ||dies|| at the end.")

      assert_includes html, %(<span class="review-spoiler">dies</span>)
      assert_includes html, "at the end."
    end

    test "render converts a spoiler marker in a body with no tags at all" do
      html = Services::Reviews::BodySanitizer.render("||everything||")

      assert_includes html, %(<span class="review-spoiler">everything</span>)
    end

    test "render converts several spoiler markers in one body" do
      html = Services::Reviews::BodySanitizer.render("||one|| and ||two||")

      assert_equal 2, html.scan("review-spoiler").length
    end

    test "render leaves an unpaired marker alone" do
      html = Services::Reviews::BodySanitizer.render("a || b")

      refute_includes html, "review-spoiler"
      assert_includes html, "a || b"
    end

    test "render escapes text around a spoiler marker" do
      html = Services::Reviews::BodySanitizer.render("<script>x</script> ||hidden||")

      refute_includes html, "<script"
      assert_includes html, %(<span class="review-spoiler">hidden</span>)
    end

    test "render escapes markup inside a spoiler marker" do
      html = Services::Reviews::BodySanitizer.render("||<script>alert(1)</script>||")

      refute_includes html, "<script"
      assert_includes html, "review-spoiler"
    end

    # The whole safety property: an attribute value is not a text node.
    test "render does not splice a span into an attribute value" do
      html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.test/||evil||">click</a>))

      refute_includes html, %(href="https://example.test/<span)
      assert_includes html, "click"
    end

    test "render wraps blank-line-separated text in paragraphs" do
      html = Services::Reviews::BodySanitizer.render("Line one.\n\nLine two.")

      assert_includes html, "<p>Line one.</p>"
      assert_includes html, "<p>Line two.</p>"
    end

    test "render turns a single newline into a line break" do
      html = Services::Reviews::BodySanitizer.render("Line one.\nStill one.")

      assert_includes html, "<br>"
    end

    test "render leaves a body that already has block markup alone" do
      html = Services::Reviews::BodySanitizer.render("<p>Migrated.</p><p>Body.</p>")

      assert_equal 2, html.scan("<p>").length
    end

    test "render converts a spoiler marker inside a paragraph" do
      html = Services::Reviews::BodySanitizer.render("Intro.\n\nHe ||dies||.")

      assert_includes html, "<p>Intro.</p>"
      assert_includes html, %(<span class="review-spoiler">dies</span>)
    end

    test "render still hardens links" do
      html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.test">x</a>))

      assert_includes html, %(rel="nofollow ugc noopener")
      assert_includes html, %(target="_blank")
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: the spoiler-marker and paragraph tests FAIL; the link-hardening and block-markup ones already pass.

- [ ] **Step 3: Add the marker constants**

In `body_sanitizer.rb`, beside the existing `SPOILER_CLASS`:

```ruby
      # Spoilers are written as ||like this||. Measured against the corpus before
      # choosing it: 0 existing bodies contain "||", 7 contain ">!", so the Discord
      # delimiter is collision-free here and the Reddit one is not.
      #
      # Non-greedy and multiline: a body with two spoilers must produce two spans, not
      # one span swallowing everything between the first and last marker, and a spoiler
      # may span a newline inside a paragraph.
      SPOILER_MARKER = "||".freeze
      SPOILER_PATTERN = /\|\|(.+?)\|\|/m
```

- [ ] **Step 4: Convert markers at render**

Add the private method, beside `harden_links`:

```ruby
      # Walks TEXT NODES ONLY. An attribute value is not a text node, so
      # <a href="||evil||"> cannot receive a spliced span -- the exact failure this
      # file's header documents from the original string-substitution attempt, avoided
      # the same way, just running in the other direction.
      #
      # Text either side of a marker pair is escaped before being reparsed, so nothing
      # a user typed can become markup: the ONLY element this introduces is the span
      # written here.
      #
      # Collected before mutating: replacing a node while traversing the same live
      # NodeSet is undefined.
      def convert_spoiler_markers(fragment)
        text_nodes = fragment.xpath(".//text()").to_a
        text_nodes.each do |node|
          content = node.content
          next unless content.include?(SPOILER_MARKER)
          next unless content.match?(SPOILER_PATTERN)

          node.replace(Nokogiri::HTML5.fragment(spoiler_html_for(content)))
        end
      end

      # String#split against a pattern with ONE capture group interleaves the captures
      # into the result, so even indices are the literal text between markers and odd
      # indices are the spoiler contents. That avoids hand-tracking match offsets, and
      # it makes the escaping rule obvious: everything gets escaped, and the only
      # element emitted is the span written here.
      #
      # The -1 limit keeps a trailing empty field, so a body ending in a spoiler does
      # not silently lose the (empty) text after it.
      def spoiler_html_for(content)
        content.split(SPOILER_PATTERN, -1).each_with_index.map { |part, index|
          if index.odd?
            %(<span class="#{SPOILER_CLASS}">#{CGI.escapeHTML(part)}</span>)
          else
            CGI.escapeHTML(part)
          end
        }.join
      end
```

**Verify `xpath(".//text()")` actually reaches top-level text nodes on a fragment** before moving on — a short review with no newlines is entirely one top-level text node, and that is the commonest body shape. If it does not, use `fragment.traverse` collecting `node.text?` into an array first. Say in your report which you used and how you checked.

- [ ] **Step 5: Move paragraph conversion into render**

Change `render` to paragraphize its input and convert markers:

```ruby
      def render
        sanitized = sanitizer.sanitize(
          paragraphize(@body.to_s),
          tags: RENDER_TAGS,
          attributes: RENDER_ATTRIBUTES
        ).to_s

        fragment = Nokogiri::HTML5.fragment(sanitized)
        scrub_classes(fragment)
        convert_spoiler_markers(fragment)
        harden_links(fragment)
        # Safe to mark: everything in the buffer came out of the sanitizer above, and
        # convert_spoiler_markers escapes every character it did not itself emit.
        fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
      end
```

`call` keeps its own `paragraphize` call for now — Task 2 removes it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: PASS, including every pre-existing test in the file.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/reviews test/lib/services/reviews
git add app/lib/services/reviews test/lib/services/reviews
git commit -m "Generate paragraph and spoiler markup at render time"
```

---

### Task 2: `call` stops transforming

**Files:**
- Modify: `web-app/app/lib/services/reviews/body_sanitizer.rb`
- Test: `web-app/test/lib/services/reviews/body_sanitizer_test.rb`

**Interfaces:**
- Produces: `BodySanitizer.call` is idempotent — `call(call(x)) == call(x)` for every input. Tasks 3 and 4 depend on that property.

> **This is the change the whole plan exists for.** Everything else is consequence. The single test that matters is idempotency: it is what makes the round-trip bug class unrepresentable rather than defended against, and it replaces the multi-cycle stability machinery written to defend it.

> **Some existing tests in this file assert the old write-time conversion** — that `call("<spoiler>x</spoiler>")` produces a span, and that re-running `call` destroys it. Those assertions describe behaviour this task deliberately removes. Update them to describe the new contract rather than deleting them outright, and say in your report exactly which ones you changed and to what.

- [ ] **Step 1: Write the failing idempotency test**

Append to the test file:

```ruby
    # THE property. call() no longer generates markup its own allowlist would reject,
    # so nothing has to un-generate it -- which is what retires for_editing and the
    # whole class of round-trip bug that cost three defects in one increment.
    test "call is idempotent" do
      [
        "Plain text.",
        "He ||dies|| at the end.",
        "Line one.\n\nLine two.",
        "Line one.\nStill one.",
        "Tom & Jerry",
        "<p>Migrated.</p><p>Body.</p>",
        "<p>With <i>tags</i> and a <a href=\"https://example.test\">link</a>.</p>",
        "||one|| and ||two||"
      ].each do |input|
        once = Services::Reviews::BodySanitizer.call(input)
        twice = Services::Reviews::BodySanitizer.call(once)

        assert_equal once, twice, "call was not idempotent for #{input.inspect}"
      end
    end

    test "call stores a spoiler marker as typed" do
      stored = Services::Reviews::BodySanitizer.call("He ||dies|| at the end.")

      assert_includes stored, "||dies||"
      refute_includes stored, "review-spoiler"
    end

    test "call stores newlines as typed" do
      stored = Services::Reviews::BodySanitizer.call("Line one.\n\nLine two.")

      assert_includes stored, "\n\n"
      refute_includes stored, "<p>"
    end

    test "call strips a spoiler tag, which is no longer input syntax" do
      stored = Services::Reviews::BodySanitizer.call("He <spoiler>dies</spoiler>.")

      refute_includes stored, "spoiler>"
      assert_includes stored, "dies"
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: FAIL — `call` still converts spoilers and paragraphs.

- [ ] **Step 3: Strip the transformations out of `call`**

```ruby
      # Sanitizes. Does NOT transform.
      #
      # Every markup transformation lives in #render instead, so what is stored is what
      # the author typed: ||spoilers|| as literal text, paragraphs as newlines. That
      # makes this method idempotent, and an idempotent write path is what makes the
      # round-trip bug class unrepresentable -- converting on write produced markup this
      # method's own allowlist rejects, so every edit path had to un-convert first, and
      # three separate production-class defects came out of that. Do not reintroduce a
      # transformation here.
      def call
        return nil if @body.blank?

        sanitized = sanitizer.sanitize(
          @body.to_s,
          tags: ALLOWED_TAGS,
          attributes: ALLOWED_ATTRIBUTES
        ).to_s

        fragment = Nokogiri::HTML5.fragment(sanitized)
        return nil if blank_text?(fragment)

        fragment.to_html
      end
```

Then delete the now-unused private `convert_spoilers` method.

- [ ] **Step 4: Update the superseded assertions**

Find every existing test asserting that `call` produces `<span class="review-spoiler">`, or that re-running `call` destroys a spoiler. Rewrite each to assert the new contract — a spoiler marker survives `call` untouched, and `call` is idempotent — keeping the test's original intent visible in its name.

- [ ] **Step 5: Run the whole file**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: PASS. Blank/whitespace-only bodies must still return `nil`, and over-length bodies must still not be truncated.

- [ ] **Step 6: Run the full suite**

Run: `bin/rails test`
Expected: failures **only** in tests that assert the removed write-time behaviour — likely `review_test.rb` and `review_state_controller_test.rb`. Note them in your report; Tasks 3 and 4 remove their causes. If anything else fails, stop and report rather than adjusting it.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/reviews test/lib/services/reviews
git add app/lib/services/reviews test/lib/services/reviews
git commit -m "Stop transforming review bodies on write"
```

---

### Task 3: Delete `for_editing`

**Files:**
- Modify: `web-app/app/lib/services/reviews/body_sanitizer.rb`
- Modify: `web-app/app/controllers/review_state_controller.rb`
- Test: `web-app/test/lib/services/reviews/body_sanitizer_test.rb`
- Test: `web-app/test/controllers/review_state_controller_test.rb`

**Interfaces:**
- Produces: `ReviewStateController#serialize` returns `review.body` unchanged. Nothing else consumes `for_editing`.

> **`for_editing` exists only because `call` used to transform.** With `call` idempotent, the stored body already is what the author typed, so the inverse has nothing to invert. Delete `for_editing`, `restore_spoiler_tags`, `restore_paragraphs` and `paragraph_source`, and every test that exercised them.

- [ ] **Step 1: Write the failing controller test**

In `web-app/test/controllers/review_state_controller_test.rb`, append inside the existing class:

```ruby
  test "returns the stored body verbatim so the author sees what they typed" do
    sign_in_as(@user, stub_auth: true)
    @review.update!(body: "He ||dies||.\n\nSecond paragraph.")

    get review_state_path(reviewable_type: "Books::Book", reviewable_id: @book.id), as: :json

    assert_equal "He ||dies||.\n\nSecond paragraph.", response.parsed_body["review"]["body"]
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/review_state_controller_test.rb`
Expected: FAIL — `for_editing` is still transforming the body on the way out.

- [ ] **Step 3: Simplify `serialize`**

In `review_state_controller.rb`, replace the `for_editing` call and the comment block above `serialize` with:

```ruby
  # The stored body is exactly what the author typed -- BodySanitizer.call sanitizes
  # but never transforms, so there is no generated markup to undo before putting it
  # back in a textarea.
  def serialize(review)
    {
      id: review.id,
      rating: review.rating,
      title: review.title,
      body: review.body
    }
  end
```

- [ ] **Step 4: Delete the inverse machinery**

From `body_sanitizer.rb`, delete: the `self.for_editing` class method and its comment block, the `for_editing` instance method and its comment block, and the private `restore_spoiler_tags`, `restore_paragraphs` and `paragraph_source` methods with their comments.

- [ ] **Step 5: Delete the tests that exercised them**

Remove every test in `body_sanitizer_test.rb` that calls `for_editing`. Do not try to preserve them against the new API — the behaviour they pinned no longer has a reason to exist.

- [ ] **Step 6: Run the affected files**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb test/controllers/review_state_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/reviews app/controllers/review_state_controller.rb test/lib/services/reviews test/controllers/review_state_controller_test.rb
git add app/lib/services/reviews app/controllers/review_state_controller.rb test/lib/services/reviews test/controllers/review_state_controller_test.rb
git commit -m "Delete for_editing: the stored body is already what was typed"
```

---

### Task 4: Simplify `Review`'s length validation

**Files:**
- Modify: `web-app/app/models/review.rb`
- Test: `web-app/test/models/review_test.rb`

**Interfaces:**
- Produces: `Review` validates `body` length against the **stored** value with a plain `validates :body, length: {maximum: MAX_BODY_LENGTH}`.

> **This machinery existed because `call` inflated bodies.** Paragraph conversion added ~7 characters per paragraph, so a 24,000-character submission could be stored at 44,000 and fail a validation the textarea had already accepted. The fix captured the pre-sanitize length in an ivar, which then had to be memoized to keep `valid?` idempotent. With `call` no longer generating markup, none of that is needed.
>
> **Be honest about what changes:** sanitizing can still grow a body through entity encoding (`&` becomes `&amp;`), so an entity-dense body near the cap can still be rejected. That was the behaviour in increments 1–3 and it is what the spec describes ("at most 25,000 characters" on the stored body). This restores it rather than inventing something new.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/models/review_test.rb`, inside the existing class:

```ruby
  test "rejects a body over the cap" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: "x" * 25_001)

    refute review.valid?
    assert_includes review.errors[:body], "is too long (maximum is 25000 characters)"
  end

  test "accepts a body at the cap" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: "x" * 25_000)

    assert review.valid?
  end

  # Regression: the pre-sanitize length machinery this replaces made valid? depend on
  # how many times it had run.
  test "validating twice gives the same answer" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: "x" * 25_000)

    assert_equal review.valid?, review.valid?
  end

  test "a saved boundary review stays savable when only the rating changes" do
    review = Review.create!(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: "x" * 25_000)

    review.reload
    review.rating = 2

    assert review.save
  end
```

- [ ] **Step 2: Run them to verify they fail or pass for the wrong reason**

Run: `bin/rails test test/models/review_test.rb`
Expected: the first three may pass under the current machinery; the point is they must still pass after Step 3. Record the before state in your report.

- [ ] **Step 3: Replace the machinery with a plain validation**

In `review.rb`: delete the `validate :validate_body_length` line and the private `validate_body_length` method with its comment block; add `body` to the declarative validations beside the existing ones:

```ruby
  validates :body, length: {maximum: MAX_BODY_LENGTH}
```

Then simplify `sanitize_body` to its whole job, deleting the ivars:

```ruby
  # BodySanitizer.call sanitizes but never transforms, so this is idempotent: running
  # it again on its own output returns the same string. That is why no length has to be
  # captured before it runs, and why validating twice gives the same answer.
  def sanitize_body
    self.body = Services::Reviews::BodySanitizer.call(body)
  end
```

- [ ] **Step 4: Run the model tests**

Run: `bin/rails test test/models/review_test.rb`
Expected: PASS, including any pre-existing length tests.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/models/review.rb test/models/review_test.rb
git add app/models/review.rb test/models/review_test.rb
git commit -m "Validate body length plainly now that call cannot inflate"
```

---

### Task 5: Convert the 119 stored spoiler spans

**Files:**
- Create: `web-app/db/migrate/<timestamp>_convert_review_spoiler_spans_to_markers.rb`
- Test: `web-app/test/lib/services/reviews/spoiler_span_converter_test.rb`
- Create: `web-app/app/lib/services/reviews/spoiler_span_converter.rb`

**Interfaces:**
- Produces: `Services::Reviews::SpoilerSpanConverter.call(html) -> String`, converting `<span class="review-spoiler">x</span>` to `||x||`. The migration uses it; Task 6 depends on the data being converted.

> **This must be a Rails migration, not a rake task.** `web-app/bin/docker-entrypoint` runs `./bin/rails db:prepare` before `rails server` starts, so a migration completes before the new code serves any request. A rake task run before merging would leave those 119 rows showing `||secret||` as literal text; run after deploying, it would leave their spoilers in the clear because Task 6 removes `span` from the render allowlist. The migration is the only ordering with no exposure window in either direction.

> **The conversion logic is a separate service so it can be tested without running the migration.** Migrations are not re-runnable and get squashed; the logic outlives it.

> **Do not use the `Review` model inside the migration.** A migration must keep working when the model changes underneath it. Define a minimal local class instead, and write with `update_column`-equivalent SQL so no callback fires.

- [ ] **Step 1: Write the failing converter test**

Create `web-app/test/lib/services/reviews/spoiler_span_converter_test.rb`:

```ruby
require "test_helper"

module Services
  module Reviews
    class SpoilerSpanConverterTest < ActiveSupport::TestCase
      def convert(html)
        Services::Reviews::SpoilerSpanConverter.call(html)
      end

      test "converts a spoiler span to a marker" do
        assert_equal "He ||dies||.", convert(%(He <span class="review-spoiler">dies</span>.))
      end

      test "converts several spans" do
        assert_equal "||one|| and ||two||",
          convert(%(<span class="review-spoiler">one</span> and <span class="review-spoiler">two</span>))
      end

      test "leaves surrounding markup intact" do
        result = convert(%(<p>He <span class="review-spoiler">dies</span>.</p>))

        assert_includes result, "<p>"
        assert_includes result, "||dies||"
      end

      test "leaves a body with no spoiler span unchanged" do
        assert_equal "<p>Nothing hidden.</p>", convert("<p>Nothing hidden.</p>")
      end

      test "leaves a span with a different class alone" do
        assert_equal %(<span class="other">x</span>), convert(%(<span class="other">x</span>))
      end

      test "is idempotent" do
        once = convert(%(He <span class="review-spoiler">dies</span>.))

        assert_equal once, convert(once)
      end

      test "returns nil for a nil body" do
        assert_nil convert(nil)
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/services/reviews/spoiler_span_converter_test.rb`
Expected: FAIL — the class does not exist.

- [ ] **Step 3: Write the converter**

Create `web-app/app/lib/services/reviews/spoiler_span_converter.rb`:

```ruby
module Services
  module Reviews
    # One-shot conversion of the spoiler spans BodySanitizer.call used to generate on
    # write into the ||marker|| syntax it now stores. Used by the migration that runs
    # before the render change serves traffic.
    #
    # Parser-based, like everything else that touches this markup: a span's inner text
    # is put back as literal text, so nothing a reader typed can become markup.
    class SpoilerSpanConverter
      SPOILER_CLASS = BodySanitizer::SPOILER_CLASS

      def self.call(html)
        return nil if html.nil?

        fragment = Nokogiri::HTML5.fragment(html.to_s)
        spans = fragment.css("span.#{SPOILER_CLASS}").to_a
        return html.to_s if spans.empty?

        spans.each { |node| node.replace(Nokogiri::XML::Text.new("||#{node.text}||", fragment.document)) }
        fragment.to_html
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/services/reviews/spoiler_span_converter_test.rb`
Expected: PASS, 7 runs.

- [ ] **Step 5: Generate the migration**

```bash
bin/rails generate migration ConvertReviewSpoilerSpansToMarkers
```

Replace its body:

```ruby
class ConvertReviewSpoilerSpansToMarkers < ActiveRecord::Migration[8.1]
  # Runs during db:prepare in bin/docker-entrypoint, BEFORE rails server starts
  # serving. That ordering is the point: the render change in this same deploy drops
  # `span` from the render allowlist, so any row still storing a spoiler span at the
  # moment traffic arrives would print its spoiler in the clear.
  #
  # A local model class, not ::Review -- a migration has to keep working when the app's
  # model changes underneath it. update_columns skips validations and callbacks, so
  # BodySanitizer never runs against a body mid-conversion.
  class MigrationReview < ActiveRecord::Base
    self.table_name = "reviews"
  end

  def up
    MigrationReview.where("body LIKE ?", "%review-spoiler%").find_each do |review|
      converted = Services::Reviews::SpoilerSpanConverter.call(review.body)
      next if converted == review.body

      review.update_columns(body: converted)
    end
  end

  # Irreversible by design: the markers are the canonical form now, and reversing would
  # regenerate markup the write path can no longer produce.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

- [ ] **Step 6: Verify against real data, read-only first**

```bash
bin/rails runner 'puts Services::Reviews::SpoilerSpanConverter.call(Review.where("body LIKE ?", "%review-spoiler%").first.body)'
```

Expected: the printed body contains `||…||` and no `review-spoiler`. **This is read-only — it prints, it does not save.**

- [ ] **Step 7: Snapshot development, then run the migration**

This migration **rewrites 119 stored bodies and declares itself irreversible**, and the development database holds books data that exists nowhere else and takes hours to rebuild. Snapshot before writing to it:

```bash
../bin/snapshot-dev-db.sh --label pre-spoiler-markers
```

(The script lives at the **repo root**, not under `web-app/`, hence the `../`. Restore with `../bin/snapshot-dev-db.sh --restore` if anything goes wrong.)

Then:

```bash
bin/rails db:migrate
bin/rails runner 'puts "remaining spans: #{Review.where("body LIKE ?", "%review-spoiler%").count}"; puts "rows with markers: #{Review.where("body LIKE ?", "%||%").count}"'
```

Expected: remaining spans **0**, rows with markers **119**. Record both numbers in your report.

- [ ] **Step 8: Run the suite and commit**

```bash
bin/rails test
bundle exec standardrb app/lib/services/reviews db/migrate test/lib/services/reviews
git add app/lib/services/reviews db/migrate db/schema.rb test/lib/services/reviews
git commit -m "Convert stored spoiler spans to markers in a migration"
```

---

### Task 6: Tighten the render allowlist

**Files:**
- Modify: `web-app/app/lib/services/reviews/body_sanitizer.rb`
- Test: `web-app/test/lib/services/reviews/body_sanitizer_test.rb`

**Interfaces:**
- Consumes: Task 5's migration, which guarantees no stored body contains a `span`.
- Produces: `RENDER_TAGS == ALLOWED_TAGS` and `RENDER_ATTRIBUTES == %w[href]`; `scrub_classes` gone.

> **This is only safe because Task 5 ran.** No stored body contains a `span` any more, and `call` cannot produce one, so the render pass has no reason to admit `span` or `class` — which means the blanket-`class` allowance that `scrub_classes` existed to narrow closes by construction. That allowance was a genuine hole: the compiled stylesheet ships `.fixed`, `.inset-0` and `.z-50`, so a class-bearing body could have overlaid the page.

- [ ] **Step 1: Write the failing tests**

Append to the test file:

```ruby
    test "render strips a user-written spoiler span" do
      html = Services::Reviews::BodySanitizer.render(%(<span class="review-spoiler">forged</span>))

      refute_includes html, "review-spoiler"
      assert_includes html, "forged"
    end

    test "render strips any class" do
      html = Services::Reviews::BodySanitizer.render(%(<p class="fixed inset-0 z-50">overlay</p>))

      refute_includes html, "fixed"
      refute_includes html, "class="
    end

    test "render strips a title attribute" do
      html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.test" title="leak">x</a>))

      refute_includes html, "leak"
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: the first two FAIL — `span` and `class` are still admitted.

- [ ] **Step 3: Tighten the constants and delete `scrub_classes`**

Replace the `RENDER_TAGS` / `RENDER_ATTRIBUTES` definitions and their comments with:

```ruby
      # Render admits exactly what write admits. They were briefly different: write
      # generated a <span class="review-spoiler"> that render then had to let through,
      # which forced a blanket `class` allowance and a scrubbing pass to narrow it back
      # down. Storing ||markers|| instead removed the reason for the difference -- the
      # only span on the page is the one convert_spoiler_markers writes AFTER this
      # sanitize pass, so neither `span` nor `class` needs to survive it.
      #
      # `title` is dropped deliberately: decorative, and on a spoiler it would leak the
      # hidden text through the browser's native tooltip.
      RENDER_TAGS = ALLOWED_TAGS
      RENDER_ATTRIBUTES = %w[href].freeze
```

Delete the private `scrub_classes` method and its call in `render`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `bin/rails test`
Expected: no failures.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/services/reviews test/lib/services/reviews
git add app/lib/services/reviews test/lib/services/reviews
git commit -m "Drop span and class from the render allowlist"
```

---

### Task 7: Convert legacy spoiler tags at import

**Files:**
- Modify: `web-app/app/lib/services/books_migration/review_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/review_migrator_test.rb`

**Interfaces:**
- Consumes: `Services::Reviews::BodySanitizer.call`, which no longer knows the `<spoiler>` tag.

> **Without this, the eventual legacy cutover publishes 119 spoilers in the clear.** The migrator calls `call`, and `call` no longer allowlists `spoiler`, so a legacy `<spoiler>Ahab dies</spoiler>` would be stripped to bare text. The cutover re-imports everything from scratch against a frozen legacy database, so this path will definitely run again.

> **Parser-based, before `call`.** Legacy bodies are untrusted HTML, so replace the element with a text node rather than substituting on the string.

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/lib/services/books_migration/review_migrator_test.rb`, inside the existing class:

```ruby
    test "converts a legacy spoiler tag into a marker before sanitizing" do
      migrator = Services::BooksMigration::ReviewMigrator.new
      migrator.stubs(:legacy_each).multiple_yields(
        [{"id" => 1, "user_id" => users(:regular_user).id, "book_id" => books_books(:war_and_peace).id,
          "rating" => 4, "title" => nil, "body" => "He <spoiler>dies</spoiler> at the end.",
          "created_at" => Time.current, "updated_at" => Time.current}]
      )

      migrator.call

      body = ::Review.find(1).body
      assert_includes body, "||dies||"
      refute_includes body, "spoiler>"
    end
```

Check the existing tests in this file for the exact `legacy_each` stubbing shape and the attribute keys the migrator expects, and match them — do not invent a different shape.

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_test.rb`
Expected: FAIL — the tag is stripped, leaving bare `dies`.

- [ ] **Step 3: Add the pre-pass**

In `review_migrator.rb`, before the `BodySanitizer.call` at line ~98, convert legacy tags:

```ruby
        body = Services::Reviews::BodySanitizer.call(convert_legacy_spoilers(attrs["body"]))
```

and add the private method:

```ruby
      # Legacy stored spoilers as a <spoiler> tag. BodySanitizer no longer knows that
      # tag -- spoilers are ||markers|| now -- so without this the sanitizer would strip
      # it and publish every legacy spoiler in the clear at the cutover.
      #
      # Parser-based, not string substitution: legacy bodies are untrusted HTML, and a
      # marker robust enough to survive naive replacement also survives inside a quoted
      # attribute value.
      def convert_legacy_spoilers(body)
        return body if body.blank?
        return body unless body.to_s.include?("<spoiler")

        fragment = Nokogiri::HTML5.fragment(body.to_s)
        fragment.css("spoiler").each do |node|
          node.replace(Nokogiri::XML::Text.new("||#{node.text}||", fragment.document))
        end
        fragment.to_html
      end
```

- [ ] **Step 4: Run the migrator tests**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_test.rb`
Expected: PASS, including every pre-existing test.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books_migration test/lib/services/books_migration
git add app/lib/services/books_migration test/lib/services/books_migration
git commit -m "Convert legacy spoiler tags to markers at import"
```

---

### Task 8: Teach the syntax, and cover it end to end

**Files:**
- Modify: `web-app/app/components/reviews/modal_component.html.erb`
- Test: `web-app/test/components/reviews/modal_component_test.rb`
- Modify: `web-app/e2e/tests/books/account/reviews-write.spec.ts`

**Interfaces:**
- Consumes: everything above.

> **Nobody can use a syntax they are not told about.** The dialog's hint currently mentions blank lines only.

- [ ] **Step 1: Write the failing component test**

Append to `web-app/test/components/reviews/modal_component_test.rb`:

```ruby
    test "tells the writer how to hide a spoiler" do
      render_inline(Reviews::ModalComponent.new)

      assert_text "||"
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/components/reviews/modal_component_test.rb`
Expected: FAIL.

- [ ] **Step 3: Extend the hint**

In `modal_component.html.erb`, replace the existing hint span with:

```erb
        <span class="label-text-alt mt-1 text-base-content/60">Leave a blank line to start a new paragraph. Wrap text in ||double pipes|| to hide a spoiler.</span>
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/components/reviews/modal_component_test.rb`
Expected: PASS.

- [ ] **Step 5: Extend the E2E write spec**

In `e2e/tests/books/account/reviews-write.spec.ts`, add a test inside the existing describe block. It must clean up after itself exactly as the neighbouring tests do:

```ts
  test('a spoiler survives being written, reloaded and edited', async ({ page }) => {
    await page.goto(BOOK);

    await page.getByTestId('review-widget-label').click();
    await page.getByTestId('review-star-button').nth(3).click();
    await page.locator('#review_modal textarea').fill('He ||dies|| at the end.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await expect(page.locator('.review-spoiler')).toHaveText('dies');

    // The author sees what they typed, not generated markup.
    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal textarea')).toHaveValue('He ||dies|| at the end.');

    // And the spoiler survives an edit -- the defect this whole change removes.
    await page.locator('#review_modal textarea').fill('He ||dies|| at the very end.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await expect(page.locator('.review-spoiler')).toHaveText('dies');
  });
```

- [ ] **Step 6: Run the specs**

```bash
yarn build:all
bin/rails server
```

In a second shell:

```bash
yarn test:e2e e2e/tests/books/account/reviews-write.spec.ts
```

Expected: all pass. Afterwards confirm the e2e user left no review rows behind, the way the existing spec's cleanup is verified.

- [ ] **Step 7: Full verification**

```bash
bin/rails test
bundle exec standardrb
```

Expected: green and clean. Record the real counts.

- [ ] **Step 8: Commit**

```bash
git add app/components/reviews test/components/reviews e2e/tests/books/account
git commit -m "Teach the spoiler syntax and cover the edit round trip end to end"
```

---

## Deployment note — read before merging

Tasks 5 and 6 **must ship in the same deploy**. `bin/docker-entrypoint` runs `db:prepare` before `rails server` starts, so the migration converts the 119 rows before the tightened render allowlist ever handles a request. Splitting them across two deploys reintroduces exactly the exposure window the migration exists to close:

- migration alone → those rows render `||secret||` as literal text
- allowlist change alone → those rows render their spoilers in the clear

There is **no separate rake task to remember after deploy**, which is a deliberate departure from increments 2 and 3.

## Deliberately not in this plan

- **The rate limit on the write endpoints** and **`Review#sanitize_body` re-running on a body-omitting `PATCH`** — both were raised during increment 4 and both belong to increment 5. Note that this change makes the second one harmless: re-running an idempotent `call` cannot destroy anything.
- **An escape hatch for a literal `||`.** No existing body contains one; add it when something demands it.
- **Accepting `<spoiler>` as input.** It is no longer allowlisted, and the dialog teaches `||`.
