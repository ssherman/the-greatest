# Share Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Book and game links unfurl in chat apps with a small cover thumbnail, every site asks only for small cards, and covers missing their dimensions get measured.

**Architecture:** The three layouts already render Open Graph tags from `content_for`. They switch to always `twitter:card=summary` and gain an optional `og:image:alt`. A shared helper decides whether a cover qualifies (≥ 200px each side, dimensions known) and returns its public URL, and the book and game show views use it. A Sidekiq job plus a rake task measures the ~6.7k migrated image blobs that were never analyzed.

**Tech Stack:** Rails 8 views and helpers, ActiveStorage (`blob.analyze`), Sidekiq, Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-13-share-previews-design.md`

## Global Constraints

- All commands run from `web-app/`. Lint with `bundle exec standardrb`. Generate jobs with `bin/rails generate sidekiq:job images/analyze_dimensions`. No brakeman.
- `twitter:card` is always `summary` on books, music and games. No page may emit `summary_large_image`.
- Minimum preview size: width **and** height ≥ **200**. If either dimension is missing, there is no `og:image`.
- `og:image` is the cover's existing public URL: `rails_public_blob_url(image.file)`, the same URL the page's `<img>` uses. No new variants.
- `og:title` for books is `"#{title} by #{author_names}"`, or the bare title when there are no authors. For games it is `"#{title} - #{developer_names}"`, or the bare title when there are no developers. Neither carries a site suffix. `og:image:alt` is the book or game title.
- Music show pages are out of scope. Don't add `og:image` to albums, songs or artists.
- Controller tests assert behaviour through `assert_select` on `meta` tags, which is the established pattern for robots meta. Check real fixture names before using them.
- Minitest 6: use `assert_nil`, never `assert_equal nil`.

## Review Focus

1. **A cover whose blob has `{"identified": true}` and no width/height**, which describes 6,756 migrated book covers. Expected: no `og:image` and no error. Pinned in Task 2.
2. **A book or game with no primary image, or an image row whose file isn't attached.** Expected: no `og:image`, page renders 200. Pinned in Task 2.
3. **A news post with a share image.** Expected: still `og:image`, but now `twitter:card=summary`. Pinned in Task 1.
4. **The backfill hitting an undecodable or missing blob.** Expected: it logs and carries on with the rest of the batch, and re-running it is harmless. Pinned in Task 3.
5. **A provisional book.** Expected: it still gets the preview. Previews aren't indexing, and the page is reachable by URL. No special case.

---

### Task 1: Small cards everywhere, plus `og:image:alt`

**Files:**
- Modify: `app/views/layouts/books/application.html.erb`, `app/views/layouts/music/application.html.erb`, `app/views/layouts/games/application.html.erb` (the `og:image` / `twitter:card` block, ~lines 18-23)
- Test: `test/controllers/news_posts_controller_test.rb` (extend)

**Interfaces:**
- Produces: the layouts honour `content_for :og_image` (already) and the new `content_for :og_image_alt`. The latter renders `<meta property="og:image:alt" content="...">` only when `og_image` is also present. Task 2 consumes both.

- [ ] **Step 1: Write failing tests** in `news_posts_controller_test.rb`. Follow the existing share-image test near line 338 for attaching:
  - `"a post with a share image asks for the small summary card"`: GET the post, then `assert_select "meta[property='og:image']", count: 1` and `assert_select "meta[name='twitter:card'][content=?]", "summary"`.
  - `"no site emits a large card"`: for each of books, music and games, `host!` that domain, GET `/news` (or a post on that domain, using fixtures that exist per domain) and `assert_select "meta[name='twitter:card'][content='summary_large_image']", count: 0`.
- [ ] **Step 2: Run** `bin/rails test test/controllers/news_posts_controller_test.rb`. Expected: the first test FAILS (currently `summary_large_image`).
- [ ] **Step 3: Implement.** In each of the three layouts, replace the if/else with an unconditional `<meta name="twitter:card" content="summary">`. Keep `og:image` inside `if content_for?(:og_image)`, and next to it render `og:image:alt` when `content_for?(:og_image_alt)`.
- [ ] **Step 4: Run** the same file. Expected: PASS. Then `bin/rails test test/controllers` to catch any existing assertion on `summary_large_image`, and update it if one exists.
- [ ] **Step 5: Commit** `"Link previews: small summary card on every site"`

---

### Task 2: Cover thumbnails on book and game pages

**Files:**
- Create: `app/helpers/share_image_helper.rb`
- Modify: `app/views/books/books/show.html.erb` (top `<% %>` block), `app/views/games/games/show.html.erb` (top block)
- Test: `test/helpers/share_image_helper_test.rb`, `test/controllers/books/books_controller_test.rb`, `test/controllers/games/games_controller_test.rb` (extend)
- E2E: `e2e/tests/books/book-detail.spec.ts` and the games game-detail spec (extend existing files; check `e2e/tests/games/` for the name)

**Interfaces:**
- Consumes: Task 1's `og_image` / `og_image_alt` content slots.
- Produces: `ShareImageHelper::MIN_DIMENSION = 200` and `share_image_url(image) -> String | nil`. `image` is an `Image` record or nil. The helper returns `rails_public_blob_url(image.file)` only when `image&.file&.attached?` and the blob's `metadata["width"]` and `metadata["height"]` are both present and ≥ `MIN_DIMENSION`. Otherwise it returns nil.

- [ ] **Step 1: Write failing tests**
  - Helper tests. Build an `Image` on a fixture book and attach a blob made with `ActiveStorage::Blob.create_and_upload!(io: File.open(file_fixture("test_image.png")), filename: "c.png", metadata: {...})`. Cases:
    - `{width: 300, height: 450, analyzed: true}` returns the URL, which equals `rails_public_blob_url(image.file)`.
    - `{width: 199, height: 450}` returns nil.
    - `{width: 300, height: 199}` returns nil.
    - `{identified: true}` (no dimensions) returns nil.
    - `share_image_url(nil)` returns nil.
    - An image with no attached file returns nil.
    - `{width: 200, height: 200}` returns the URL (the boundary is inclusive).
  - Books controller tests: with a qualifying cover on a fixture book:
    - `assert_select "meta[property='og:image'][content=?]", <the cover url>`
    - `meta[property='og:image:alt'][content=?]` equals the title
    - `meta[property='og:title'][content=?]` equals `"#{title} by #{author names joined ", "}"`
    - A book with no cover has `og:image` count 0.
    - A book whose cover is `{identified: true}` has `og:image` count 0 and responds `:success`.
  - Games controller tests: the same three cases. `og:title` equals `"#{title} - #{developer names}"`.
- [ ] **Step 2: Run** `bin/rails test test/helpers/share_image_helper_test.rb test/controllers/books/books_controller_test.rb test/controllers/games/games_controller_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** the helper, then in each show view's top block:
  - `url = share_image_url(@book.primary_image)` (`@game` for games)
  - when present, set `content_for :og_image, url` and `content_for :og_image_alt, @book.title`
  - set `content_for :og_title` per Global Constraints, reusing the view's existing `author_names` / `@developer_names`
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: E2E.** Extend the book-detail and game-detail specs. On a page whose cover has dimensions in the dev DB, expect `meta[property="og:image"]` to have a `content` starting with `https://` and `meta[name="twitter:card"]` to be `summary`. Pick the page through existing spec conventions, not a hard-coded id, if the spec already navigates from the index. Before running, confirm port 3000 belongs to this worktree using the AGENTS.md snippet. If it doesn't, stop and report. Start with `yarn build:all` and `bin/rails server`, and stop the server afterwards.
- [ ] **Step 6: Commit** `"Link previews: cover thumbnail on book and game pages"`

---

### Task 3: Measure covers that were never analyzed

**Files:**
- Create (generator): `app/sidekiq/images/analyze_dimensions_job.rb`, `test/sidekiq/images/analyze_dimensions_job_test.rb`
- Create: `lib/tasks/images.rake`
- Modify: `docs/launch-todo.md` (new final section)

**Interfaces:**
- Produces:
  - `Images::AnalyzeDimensionsJob#perform(blob_ids)` with `blob_ids` an Array of Integer. For each `ActiveStorage::Blob` found, it calls `blob.analyze` unless the blob already has `metadata["width"]`. It rescues `StandardError` per blob with `Rails.logger.error` naming the blob id and carries on.
  - `rake images:analyze_missing_dimensions` selects the ids of blobs attached as `Image#file` (`active_storage_attachments.record_type = 'Image' AND name = 'file'`) whose `metadata->>'width'` is null, and enqueues `perform_async` in slices of **500**. It prints the blob count and job count.

- [ ] **Step 1: Write failing job tests** (Sidekiq inline is global in tests):
  - A blob created with `metadata: {identified: true}` from `file_fixture("test_image.png")` has integer `width` and `height` after `perform([blob.id])`.
  - A blob that already has width/height isn't re-analyzed: `ActiveStorage::Blob.any_instance.expects(:analyze).never`, or stub and assert.
  - With two blobs where the first raises (stub `analyze` to raise on that instance), the second still gets measured and the job doesn't raise.
  - An unknown id is skipped without error.
- [ ] **Step 2: Run** `bin/rails test test/sidekiq/images/analyze_dimensions_job_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** the job and rake task. Use `sidekiq_options queue: :low` if the app defines that queue; check `config/sidekiq.yml`.
- [ ] **Step 4: Run** the job test. Expected: PASS. Then `bin/rails -T images` lists the task.
- [ ] **Step 5: launch-todo.** Add a short final section, "Measure migrated cover images (once)". Explain that 6,756 book covers from the July 2026 image migration were never measured, so they get no link-preview thumbnail until they are. After deploy, run `bin/rails images:analyze_missing_dimensions` in production. It is safe to re-run, because it only touches blobs still missing a width. Note that the dev and production buckets differ, so dev needs its own run.
- [ ] **Step 6: Full verification:** `bin/rails test` (no new warnings), `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`.
- [ ] **Step 7: Commit** `"Images: backfill job to measure covers missing dimensions"`
