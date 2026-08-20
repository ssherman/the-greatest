# News Posts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy books blog with a Markdown-backed news section on books, music and games — admin-managed topics, share-card metadata, an RSS feed — and migrate the 31 existing books posts.

**Architecture:** Three new global-namespace tables (`news_posts`, `news_topics`, `news_post_topics`) with a `domain` enum, so one model, one controller and one set of views serve all three sites. `news_posts.body` stores Markdown **exactly as typed**; HTML is generated on read by `Services::News::BodyRenderer`. Nothing transforms the body on write. Public routes are global (non-domain-constrained) like `/membership` and `/my/lists`, with `DomainLayout#resolve_layout` picking the layout from `Current.domain`.

**Tech Stack:** Rails 8.1, `commonmarker` 2.9.0 (Markdown → HTML), `reverse_markdown` 3.0.2 (one-time migration only), `friendly_id`, `pagy` 43, Active Storage on Cloudflare R2, Minitest + Mocha + fixtures, Stimulus, daisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-19-news-posts-design.md` — read it before starting. This plan implements all six of its increments.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Working directory is `web-app/`** for all Rails/yarn commands. `docs/` is at the **project root**, not `web-app/docs/`.
- **Linter is `bundle exec standardrb`** — never `bin/rubocop`. Run it before every commit.
- **Full suite is `bin/rails test`.** Baseline on this branch, measured 2026-08-19: **7003 runs, 160919 assertions, 0 failures, 0 errors, 0 skips.** Any new failure is yours.
- **Do NOT run brakeman.** The owner does not use it.
- **Use Rails generators** — never hand-create models/controllers/components. `bin/rails generate model NewsTopic ...` creates the matching test file.
- **Services live in `app/lib/services/<domain>/`**, not `app/services/`.
- **Rails 8 enum syntax:** `enum :domain, {books: 2}` — colon prefix, never `enum domain: {...}`.
- **Nested namespace shadowing.** Inside `Services::BooksMigration` a bare `Books::Book` resolves to the *nested* module and raises a confusing `NameError`. Root-anchor `::Books::Book`, `::User`, `::NewsPost` inside every `Services::` namespace, in production **and** test files. This has bitten this codebase 3+ times.
- **The development database is not disposable.** Books data exists ONLY in development and takes hours to rebuild. Never run `db:drop`/`db:reset`/`db:schema:load`, bulk `delete_all`/`destroy_all`, or raw `DROP`/`TRUNCATE`/`DELETE FROM` against development. `ActiveRecord::FixtureSet.create_fixtures` **TRUNCATES every table it names** — it is not a read. To inspect a fixture, read the YAML.
- **Snapshot before the migration run:** `bin/snapshot-dev-db.sh --label pre-news-migration`, restore with `bin/snapshot-dev-db.sh --restore`.
- **daisyUI 5, not 4.** These ten classes fail **silently** and are blocked by `test/lint/daisyui_v4_classes_test.rb` with an **empty allowlist**: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`/`checkbox`. When the guard fails, remove the class — never add an allowlist entry.
- **Colour:** the books theme's `success` token is **purple on purpose** — never change it to green. Never convey draft-vs-published by colour alone, and never green-versus-red.
- **Turbo frames trap links.** Every `<a>` inside a `turbo_frame_tag` navigates *that frame*. Any frame whose contents link off-page needs `target: "_top"`. Guarded by `assert_no_frame_trapped_links`, which checks **anchors only** — a form inside a `target: "_top"` frame that must update the frame in place needs `data: {turbo_frame: "<frame_id>"}` explicitly.
- **Turbo form failures must be turbo-streams.** A non-2xx response *without* a turbo-stream body makes Turbo replace the whole page, so `head :unprocessable_entity` blanks it. Render the form back with `status: :unprocessable_entity`.
- **Long user text needs `overflow-wrap: anywhere`** — `break-words` does NOT fix the whole-page sideways scroll.
- **Integration tests set the host** with `host! "dev-new.thegreatestbooks.org"` (see `test/controllers/books/global_canon_controller_test.rb:6`). `sign_in_as(user, stub_auth: true)` is defined in `test/test_helper.rb:38`. JSON requests use `as: :json`.
- **`rails-controller-testing` is NOT in the Gemfile** — `assert_template` and `assigns` do not exist. Use `@controller.view_assigns["name"]`, `assert_select`, or `response.body`.
- **Fixtures insert directly via SQL and skip callbacks**, so every fixture row must set `slug` explicitly — friendly_id will not generate it.
- **Check actual fixture names before referencing** — they are semantic (`regular_user`, `admin_user`, `editor_user`), never `one`/`two`.
- **`assert_empty` hides broken code.** An empty result is what a working filter AND a deleted filter both produce. Assert `assert_equal [expected_id], actual_ids`. **Delete the code under test and watch the test go red before trusting it** — this applies to Capybara/component assertions too, where `text:` is a substring match with `default_normalize_ws` false.
- **Sort tests must not coincide with fixture id order.** Fixture timestamps are per-**file**, so a `created_at` tiebreak resolves on `id` and hashed ids routinely match the order being asserted. Give sort fixtures explicit, deliberately-not-id-ordered timestamps.
- **Every new user-facing page needs a Playwright E2E test** in `web-app/e2e/tests/`. CI does **not** run Playwright or system tests — those stay local.
- **Worktree hazards.** Work happens in `.claude/worktrees/news-posts` (branch `news-posts`). A worktree isolates **files only**: set `COMPOSE_PROJECT_NAME=the-greatest` for any `docker compose`; **diff `schema.rb` before every commit** because `db:migrate` imports other agents' migrations; the test database is shared, so a worktree's own new tables can vanish from `the_greatest_test` when anything runs from the main checkout — re-run `bin/rails db:test:prepare` if a table disappears; the git stash stack is global. `.env` is already symlinked.
- **Commit after every task.** Branch off `main`, commit freely. Do **not** push or open a PR without asking.

---

## Verified facts this plan depends on

All measured on 2026-08-19 in this worktree. Do not re-derive; do not contradict.

| Fact | Value |
| --- | --- |
| Legacy posts | 31, all `blog_id: 1`, all `user_id: 1141`, all `active: true` |
| `front_page` | true on 27 of 31, **read by no code** |
| `pinned` | **0 of 31** |
| Non-empty `tags` | **0 of 31** |
| Legacy tag vocabulary | exactly `a, br, strong, h1, ul, ol, li, div` |
| Bodies with `<img>` or `<action-text-attachment>` | 0 |
| `users.id` 1141 | exists in the new app already, `role` = 1 |
| `Rails::HTML5::SafeListSanitizer` | present and working |
| commonmarker anchor injection | ON by default; disabled with `extension: {header_ids: nil}` |
| Round-trip text equality over all 31 posts | **31/31**, but only with the punctuation tidy *and* the block-aware normalizer (Task 6) |

**The two traps proven by measurement, both of which the naive implementation walks into:**

1. **`Commonmarker.to_html` injects heading anchors by default** — `<h1 id="x">Title<a href="#x" class="anchor"></a></h1>`. The sanitizer strips `class` and `aria-label` but keeps `href`, leaving an empty `<a href="#x">` inside every heading. `extension: {header_ids: nil}` removes them at the source.
2. **`reverse_markdown` emits `**bold** :` for `<strong>bold</strong>:`** — a stray space before punctuation that immediately followed a closing inline tag. It affects 2 of the 31 posts and renders visibly wrong. Task 6's `tidy_punctuation` closes it; the round-trip assertion is what catches it.

---

## File Structure

**Increment 1 — data model and renderer**

| File | Responsibility |
|---|---|
| `db/migrate/*_create_news_topics.rb` | `news_topics` table |
| `db/migrate/*_create_news_posts.rb` | `news_posts` table |
| `db/migrate/*_create_news_post_topics.rb` | join table |
| `app/models/news_topic.rb` | topic: name, slug, domain |
| `app/models/news_post.rb` | post: title, slug, body (Markdown), summary, published_at |
| `app/models/news_post_topic.rb` | join |
| `app/lib/services/news/body_renderer.rb` | Markdown → sanitized HTML. The ONLY place Markdown becomes HTML |
| `app/lib/services/news/plain_text.rb` | block-aware HTML → text. Shared by excerpts and the migration's round-trip check |

**Increment 2 — migration**

| File | Responsibility |
|---|---|
| `app/models/legacy_books/blog_post.rb` | read-only legacy `blog_posts` |
| `app/models/legacy_books/rich_text.rb` | read-only legacy `action_text_rich_texts` |
| `app/lib/services/books_migration/news_body_converter.rb` | legacy HTML → Markdown, incl. the punctuation tidy |
| `app/lib/services/books_migration/news_post_migrator.rb` | the migration itself + round-trip verification |
| `lib/tasks/data_migration.rake` (modify) | `data_migration:news_posts` |

**Increment 3 — books admin**

| File | Responsibility |
|---|---|
| `app/controllers/admin/news_topics_base_controller.rb` | domain-agnostic topic CRUD |
| `app/controllers/admin/news_posts_base_controller.rb` | domain-agnostic post CRUD + preview |
| `app/controllers/admin/books/news_topics_controller.rb` | books subclass: domain + path helpers |
| `app/controllers/admin/books/news_posts_controller.rb` | books subclass: domain + path helpers |
| `app/views/admin/news_topics/*` | shared topic views |
| `app/views/admin/news_posts/*` | shared post views |
| `app/javascript/controllers/admin/markdown_preview_controller.js` | debounced preview refresh |
| `app/lib/admin/domain_nav.rb` (modify) | "News" sidebar entry |
| `config/routes.rb` (modify) | books admin routes |

**Increment 4 — books public**

| File | Responsibility |
|---|---|
| `app/controllers/news_posts_controller.rb` | index, show, topic — all three sites |
| `app/views/news_posts/index.html.erb` | list |
| `app/views/news_posts/show.html.erb` | one post |
| `app/views/news_posts/_card.html.erb` | one row on the index |
| `app/views/layouts/books/application.html.erb` (modify) | Open Graph / Twitter meta |
| `config/routes.rb` (modify) | global `/news` routes + books-scoped legacy 301s |
| `e2e/tests/books/news.spec.ts` | Playwright |

**Increment 5 — RSS**

| File | Responsibility |
|---|---|
| `app/views/news_posts/index.rss.builder` | feed |

**Increment 6 — games and music**

| File | Responsibility |
|---|---|
| `app/controllers/admin/{music,games}/news_{posts,topics}_controller.rb` | domain subclasses |
| `app/views/layouts/{music,games}/application.html.erb` (modify) | Open Graph meta |
| `config/routes.rb` (modify) | music and games admin routes |
| `e2e/tests/{music,games}/news.spec.ts` | Playwright |

---

# Increment 1 — Data model and renderer

### Task 1: NewsTopic

**Files:**
- Create: `db/migrate/<timestamp>_create_news_topics.rb`
- Create: `app/models/news_topic.rb`
- Create: `test/fixtures/news_topics.yml`
- Test: `test/models/news_topic_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `NewsTopic` with `enum :domain, {music: 0, games: 1, books: 2, movies: 3}`, `scope :sorted_by_name`, `#to_param → slug`. Fixture names `books_rankings`, `books_new_lists`, `music_site_news`.

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model NewsTopic domain:integer name:string slug:string
```

- [ ] **Step 2: Replace the migration**

Overwrite `db/migrate/<timestamp>_create_news_topics.rb`:

```ruby
class CreateNewsTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :news_topics do |t|
      t.integer :domain, null: false
      t.string :name, null: false
      t.string :slug, null: false

      t.timestamps
    end

    add_index :news_topics, [:domain, :slug], unique: true
  end
end
```

- [ ] **Step 3: Write the failing test**

Overwrite `test/models/news_topic_test.rb`:

```ruby
require "test_helper"

class NewsTopicTest < ActiveSupport::TestCase
  test "requires a name" do
    topic = NewsTopic.new(domain: :books)
    assert_not topic.valid?
    assert_includes topic.errors[:name], "can't be blank"
  end

  test "requires a domain" do
    topic = NewsTopic.new(name: "Rankings")
    assert_not topic.valid?
    assert_includes topic.errors[:domain], "can't be blank"
  end

  test "generates a slug from the name" do
    topic = NewsTopic.create!(domain: :books, name: "Feature Launch")
    assert_equal "feature-launch", topic.slug
  end

  test "the same slug may exist once per domain" do
    NewsTopic.create!(domain: :books, name: "Site News")
    music = NewsTopic.create!(domain: :music, name: "Site News")

    assert_equal "site-news", music.slug
  end

  test "a duplicate slug within one domain gets a suffix" do
    NewsTopic.create!(domain: :books, name: "Site News")
    second = NewsTopic.create!(domain: :books, name: "Site News")

    assert_not_equal "site-news", second.slug
  end

  test "the slug does not change when the name changes" do
    topic = NewsTopic.create!(domain: :books, name: "Rankings")
    topic.update!(name: "Ranking Updates")

    assert_equal "rankings", topic.slug
  end

  test "sorted_by_name orders alphabetically" do
    # Deliberately NOT fixture-id order -- a sort assertion that coincides with
    # id order passes against a deleted order clause.
    names = NewsTopic.books.sorted_by_name.pluck(:name)
    assert_equal names.sort, names
  end

  test "to_param is the slug" do
    assert_equal news_topics(:books_rankings).slug, news_topics(:books_rankings).to_param
  end

  test "domain enum maps books to 2, matching DomainRole" do
    assert_equal DomainRole.domains["books"], NewsTopic.domains["books"]
    assert_equal DomainRole.domains["music"], NewsTopic.domains["music"]
    assert_equal DomainRole.domains["games"], NewsTopic.domains["games"]
  end
end
```

- [ ] **Step 4: Write the fixtures**

Create `test/fixtures/news_topics.yml`:

```yaml
# Slugs are set explicitly: fixtures INSERT directly and never run friendly_id's
# callbacks, so an omitted slug violates the NOT NULL constraint.
books_rankings:
  domain: 2
  name: Rankings
  slug: rankings

books_new_lists:
  domain: 2
  name: New Lists
  slug: new-lists

books_feature_launch:
  domain: 2
  name: Feature Launch
  slug: feature-launch

music_site_news:
  domain: 0
  name: Site News
  slug: site-news
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bin/rails db:test:prepare && bin/rails test test/models/news_topic_test.rb`
Expected: FAIL — the model has no validations, no enum, no friendly_id.

- [ ] **Step 6: Write the model**

Overwrite `app/models/news_topic.rb`:

```ruby
class NewsTopic < ApplicationRecord
  extend FriendlyId

  # Scoped to :domain, so books and music may each hold a "site-news".
  # :finders is deliberately absent -- with a scoped slug, NewsTopic.find("x")
  # could resolve to another domain's row. Always scope first, then
  # .friendly.find.
  friendly_id :name, use: [:slugged, :scoped], scope: :domain

  # Same integer mapping as DomainRole so the two can never disagree about
  # which site an integer means.
  enum :domain, {music: 0, games: 1, books: 2, movies: 3}

  has_many :news_post_topics, dependent: :destroy
  has_many :news_posts, through: :news_post_topics

  validates :name, presence: true
  validates :domain, presence: true

  scope :sorted_by_name, -> { order(:name) }

  def to_param = slug

  # A topic's slug is a public URL. Renaming the topic must not move its filter
  # page, so the slug is generated once and then frozen -- Category
  # regenerates on rename; this deliberately does not.
  def should_generate_new_friendly_id? = slug.blank?
end
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/news_topic_test.rb`
Expected: PASS, 8 runs.

- [ ] **Step 8: Verify the tests are not vacuous**

Comment out `validates :name, presence: true`, re-run, confirm the "requires a name" test goes RED. Comment out `should_generate_new_friendly_id?`, re-run, confirm "the slug does not change" goes RED. Restore both.

- [ ] **Step 9: Lint, diff the schema, commit**

```bash
bundle exec standardrb --fix app/models/news_topic.rb test/models/news_topic_test.rb
git diff db/schema.rb   # must contain ONLY news_topics -- another agent's migrations import silently
git add db/migrate db/schema.rb app/models/news_topic.rb test/models/news_topic_test.rb test/fixtures/news_topics.yml
git commit -m "feat(news): add NewsTopic model"
```

---

### Task 2: NewsPost

**Files:**
- Create: `db/migrate/<timestamp>_create_news_posts.rb`
- Create: `app/models/news_post.rb`
- Create: `test/fixtures/news_posts.yml`
- Test: `test/models/news_post_test.rb`

**Interfaces:**
- Consumes: `NewsTopic` from Task 1.
- Produces: `NewsPost` with `scope :published`, `scope :recent`, `#published?`, `#draft?`, `#to_param → slug`, `has_one_attached :share_image`, `has_many_attached :body_images`. Fixture names `books_december_update` (published), `books_draft` (draft), `books_scheduled` (future), `music_launch`.

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model NewsPost domain:integer title:string slug:string body:text summary:text published_at:datetime user:references
```

- [ ] **Step 2: Replace the migration**

```ruby
class CreateNewsPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :news_posts do |t|
      t.integer :domain, null: false
      t.string :title, null: false
      t.string :slug, null: false
      t.text :body, null: false
      t.text :summary
      t.datetime :published_at
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :news_posts, [:domain, :slug], unique: true
    add_index :news_posts, [:domain, :published_at], order: {published_at: :desc}
  end
end
```

- [ ] **Step 3: Write the failing test**

Overwrite `test/models/news_post_test.rb`:

```ruby
require "test_helper"

class NewsPostTest < ActiveSupport::TestCase
  test "requires a title" do
    post = NewsPost.new(domain: :books, body: "x", user: users(:admin_user))
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  test "requires a body" do
    post = NewsPost.new(domain: :books, title: "x", user: users(:admin_user))
    assert_not post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end

  test "generates a slug from the title" do
    post = NewsPost.create!(domain: :books, title: "A Big Update", body: "hi", user: users(:admin_user))
    assert_equal "a-big-update", post.slug
  end

  test "the slug does not change when the title changes" do
    post = NewsPost.create!(domain: :books, title: "A Big Update", body: "hi", user: users(:admin_user))
    post.update!(title: "A Bigger Update")

    assert_equal "a-big-update", post.slug
  end

  test "published excludes drafts and future posts" do
    assert_equal [news_posts(:books_december_update).id],
      NewsPost.books.published.pluck(:id)
  end

  test "published includes a post published exactly now" do
    post = NewsPost.create!(domain: :books, title: "Now", body: "hi",
      user: users(:admin_user), published_at: Time.current)

    assert_includes NewsPost.books.published.pluck(:id), post.id
  end

  test "recent orders by published_at descending" do
    older = news_posts(:books_december_update)
    newer = NewsPost.create!(domain: :books, title: "Newer", body: "hi",
      user: users(:admin_user), published_at: 1.hour.ago)

    assert_equal [newer.id, older.id], NewsPost.books.published.recent.pluck(:id)
  end

  test "published? is false for a draft" do
    assert_not news_posts(:books_draft).published?
    assert news_posts(:books_draft).draft?
  end

  test "published? is false for a future publish date" do
    assert_not news_posts(:books_scheduled).published?
  end

  test "published? is true for a past publish date" do
    assert news_posts(:books_december_update).published?
    assert_not news_posts(:books_december_update).draft?
  end

  test "topics are reachable through the join" do
    assert_equal [news_topics(:books_rankings).id],
      news_posts(:books_december_update).news_topics.pluck(:id)
  end

  test "excerpt uses the summary when present" do
    assert_equal "The December update.", news_posts(:books_december_update).excerpt
  end

  test "excerpt falls back to the rendered body as plain text" do
    post = NewsPost.new(domain: :books, title: "x", body: "# Heading\n\nFirst line.\n\nSecond line.")

    assert_equal "Heading First line. Second line.", post.excerpt
  end

  test "excerpt truncates at the limit" do
    post = NewsPost.new(domain: :books, title: "x", body: "word " * 200)

    assert_operator post.excerpt(limit: 50).length, :<=, 50
  end

  test "to_param is the slug" do
    assert_equal "december-update", news_posts(:books_december_update).to_param
  end
end
```

- [ ] **Step 4: Write the fixtures**

Create `test/fixtures/news_posts.yml`:

```yaml
# Explicit published_at values, deliberately NOT in fixture-id order, so a sort
# assertion cannot pass by coinciding with hashed id order.
# books_december_update is the ONLY published books post -- several tests assert
# an exact id list against it.
books_december_update:
  domain: 2
  title: December Update
  slug: december-update
  body: |
    Just an update, since I have not posted in a while.

    **Rankings** refreshed this month.
  summary: The December update.
  published_at: <%= 3.days.ago.to_fs(:db) %>
  user: admin_user

books_draft:
  domain: 2
  title: Something Unfinished
  slug: something-unfinished
  body: Not ready yet.
  published_at:
  user: admin_user

books_scheduled:
  domain: 2
  title: Next Week
  slug: next-week
  body: Scheduled for later.
  published_at: <%= 7.days.from_now.to_fs(:db) %>
  user: admin_user

music_launch:
  domain: 0
  title: The Greatest Music Is Live
  slug: the-greatest-music-is-live
  body: We are live.
  published_at: <%= 2.days.ago.to_fs(:db) %>
  user: admin_user
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bin/rails db:test:prepare && bin/rails test test/models/news_post_test.rb`
Expected: FAIL — no validations, no enum, no scopes, no `excerpt`.

- [ ] **Step 6: Write the model**

Overwrite `app/models/news_post.rb`:

```ruby
class NewsPost < ApplicationRecord
  extend FriendlyId

  EXCERPT_LIMIT = 200

  # Scoped to :domain -- books and music may each hold a "december-update".
  # :finders is deliberately absent: with a scoped slug a bare find("x") could
  # resolve to another domain's post. Always scope first, then .friendly.find.
  friendly_id :title, use: [:slugged, :scoped], scope: :domain

  # Same integer mapping as DomainRole so the two can never disagree about
  # which site an integer means.
  enum :domain, {music: 0, games: 1, books: 2, movies: 3}

  belongs_to :user
  has_many :news_post_topics, dependent: :destroy
  has_many :news_topics, through: :news_post_topics

  # Its own attachment rather than the polymorphic Image model: Image's variants
  # cap at 250x250 with preprocessed: true, so widening them would touch every
  # book cover and album art record in the app.
  has_one_attached :share_image do |attachable|
    attachable.variant :card, resize_to_limit: [1200, 630], preprocessed: true
  end

  # Uploaded in admin; the author pastes the returned URL into the body as
  # ![alt](url). No editor integration.
  has_many_attached :body_images

  validates :title, presence: true
  validates :body, presence: true
  validates :domain, presence: true

  # A NULL published_at is excluded by SQL three-valued logic -- NULL <= now is
  # NULL, which is not true -- so this single predicate covers drafts and
  # future-dated posts alike.
  scope :published, -> { where(published_at: ..Time.current) }
  scope :recent, -> { order(published_at: :desc, id: :desc) }

  def published? = published_at.present? && published_at <= Time.current

  def draft? = !published?

  # Summary when the author wrote one, otherwise plain text derived from the
  # RENDERED body. Deriving from the Markdown source instead would leak "**"
  # and "[]()" into meta descriptions and the feed.
  def excerpt(limit: EXCERPT_LIMIT)
    return summary if summary.present?

    text = Services::News::PlainText.call(Services::News::BodyRenderer.call(body))
    text.truncate(limit, separator: " ")
  end

  def to_param = slug

  # A published post's URL is a permanent link, so retitling must not move it.
  def should_generate_new_friendly_id? = slug.blank?
end
```

- [ ] **Step 7: Run the test to verify it still fails on excerpt only**

Run: `bin/rails test test/models/news_post_test.rb`
Expected: the three `excerpt` tests FAIL with `NameError: uninitialized constant Services::News` — the renderer arrives in Task 4. Everything else PASSES. Leave them failing and continue; Task 4 closes them.

- [ ] **Step 8: Commit**

```bash
bundle exec standardrb --fix app/models/news_post.rb test/models/news_post_test.rb
git diff db/schema.rb
git add db/migrate db/schema.rb app/models/news_post.rb test/models/news_post_test.rb test/fixtures/news_posts.yml
git commit -m "feat(news): add NewsPost model"
```

---

### Task 3: NewsPostTopic join

**Files:**
- Create: `db/migrate/<timestamp>_create_news_post_topics.rb`
- Create: `app/models/news_post_topic.rb`
- Create: `test/fixtures/news_post_topics.yml`
- Test: `test/models/news_post_topic_test.rb`

**Interfaces:**
- Consumes: `NewsPost`, `NewsTopic`.
- Produces: `NewsPostTopic` with `belongs_to :news_post`, `belongs_to :news_topic`, uniqueness on the pair.

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model NewsPostTopic news_post:references news_topic:references
```

- [ ] **Step 2: Replace the migration**

```ruby
class CreateNewsPostTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :news_post_topics do |t|
      t.references :news_post, null: false, foreign_key: true
      t.references :news_topic, null: false, foreign_key: true

      t.timestamps
    end

    add_index :news_post_topics, [:news_post_id, :news_topic_id], unique: true
  end
end
```

- [ ] **Step 3: Write the failing test**

Overwrite `test/models/news_post_topic_test.rb`:

```ruby
require "test_helper"

class NewsPostTopicTest < ActiveSupport::TestCase
  test "the same topic cannot be attached to a post twice" do
    duplicate = NewsPostTopic.new(
      news_post: news_posts(:books_december_update),
      news_topic: news_topics(:books_rankings)
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:news_topic_id], "has already been taken"
  end

  test "a topic may be attached to a different post" do
    link = NewsPostTopic.new(
      news_post: news_posts(:books_draft),
      news_topic: news_topics(:books_rankings)
    )

    assert link.valid?
  end

  test "destroying a post destroys its topic links but not the topics" do
    post = news_posts(:books_december_update)

    assert_difference -> { NewsPostTopic.count }, -1 do
      assert_no_difference -> { NewsTopic.count } do
        post.destroy!
      end
    end
  end
end
```

- [ ] **Step 4: Write the fixture**

Create `test/fixtures/news_post_topics.yml`:

```yaml
december_update_rankings:
  news_post: books_december_update
  news_topic: books_rankings
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bin/rails db:test:prepare && bin/rails test test/models/news_post_topic_test.rb`
Expected: FAIL — no uniqueness validation.

- [ ] **Step 6: Write the model**

Overwrite `app/models/news_post_topic.rb`:

```ruby
class NewsPostTopic < ApplicationRecord
  belongs_to :news_post
  belongs_to :news_topic

  # Mirrors the unique index. The index is the real guarantee; this turns a
  # duplicate into a validation error rather than a RecordNotUnique from the
  # admin form's checkbox list.
  validates :news_topic_id, uniqueness: {scope: :news_post_id}
end
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/news_post_topic_test.rb`
Expected: PASS, 3 runs.

- [ ] **Step 8: Commit**

```bash
bundle exec standardrb --fix app/models/news_post_topic.rb test/models/news_post_topic_test.rb
git diff db/schema.rb
git add db/migrate db/schema.rb app/models/news_post_topic.rb test/models/news_post_topic_test.rb test/fixtures/news_post_topics.yml
git commit -m "feat(news): add NewsPostTopic join model"
```

---

### Task 4: BodyRenderer and PlainText

**Files:**
- Modify: `Gemfile`
- Create: `app/lib/services/news/body_renderer.rb`
- Create: `app/lib/services/news/plain_text.rb`
- Test: `test/lib/services/news/body_renderer_test.rb`
- Test: `test/lib/services/news/plain_text_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Services::News::BodyRenderer.call(markdown) → ActiveSupport::SafeBuffer` (HTML)
  - `Services::News::PlainText.call(html) → String` (block-aware, whitespace-collapsed, never `.text` on the whole fragment)
  - `Services::News::BodyRenderer::ALLOWED_TAGS`, `::ALLOWED_ATTRIBUTES`

- [ ] **Step 1: Add the gem**

Add to `Gemfile` beneath the existing content gems:

```ruby
# Markdown for news post bodies. Rendered at read time; the stored body is
# always the author's Markdown source.
gem "commonmarker", "~> 2.9"
```

Run: `bundle install`

- [ ] **Step 2: Write the failing PlainText test**

Create `test/lib/services/news/plain_text_test.rb`:

```ruby
require "test_helper"

module Services
  module News
    class PlainTextTest < ActiveSupport::TestCase
      test ".call returns an empty string for nil" do
        assert_equal "", PlainText.call(nil)
      end

      test ".call separates adjacent blocks" do
        # Calling .text on the fragment instead yields "onetwo". This is the
        # whole reason this class exists.
        assert_equal "one two", PlainText.call("<p>one</p><p>two</p>")
      end

      test ".call separates legacy divs the same way as paragraphs" do
        assert_equal "one two", PlainText.call("<div>one</div><div>two</div>")
      end

      test ".call turns a br into a space rather than dropping it" do
        assert_equal "one two", PlainText.call("one<br>two")
      end

      test ".call separates list items" do
        assert_equal "a b", PlainText.call("<ul><li>a</li><li>b</li></ul>")
      end

      test ".call collapses runs of whitespace" do
        assert_equal "a b", PlainText.call("<p>a</p>\n\n   <p>b</p>")
      end

      test ".call keeps inline text unseparated" do
        assert_equal "a bold word", PlainText.call("<p>a <strong>bold</strong> word</p>")
      end
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/lib/services/news/plain_text_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::News::PlainText`.

- [ ] **Step 4: Write PlainText**

Create `app/lib/services/news/plain_text.rb`:

```ruby
module Services
  module News
    # HTML to plain text, inserting a separator at every BLOCK boundary.
    #
    # Do NOT replace this with `Nokogiri::HTML5.fragment(html).text`. That
    # concatenates across blocks -- "<p>one</p><p>two</p>" becomes "onetwo" and
    # "one<br>two" becomes "onetwo" -- which is how a <br> silently vanishes and
    # two sentences fuse into one. It also makes the migration's round-trip
    # check compare a legacy <div>-per-paragraph body against a rendered
    # <p>-per-paragraph body and report a false mismatch on every multi-block
    # post; measured on the real corpus, that was 2 of 31.
    #
    # Used by NewsPost#excerpt and by the migration's round-trip verification,
    # which must normalise both sides identically.
    class PlainText
      BLOCK_TAGS = %w[
        p div br hr pre blockquote
        h1 h2 h3 h4 h5 h6
        ul ol li table tr th td
      ].freeze

      def self.call(html)
        return "" if html.blank?

        fragment = Nokogiri::HTML5.fragment(html.to_s)
        fragment.css(BLOCK_TAGS.join(",")).each do |node|
          node.add_previous_sibling(Nokogiri::XML::Text.new(" ", fragment.document))
        end

        fragment.text.gsub(/[[:space:]]+/, " ").strip
      end
    end
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bin/rails test test/lib/services/news/plain_text_test.rb`
Expected: PASS, 7 runs.

- [ ] **Step 6: Write the failing BodyRenderer test**

Create `test/lib/services/news/body_renderer_test.rb`:

```ruby
require "test_helper"

module Services
  module News
    class BodyRendererTest < ActiveSupport::TestCase
      test ".call returns an empty safe buffer for nil" do
        assert_equal "", BodyRenderer.call(nil)
        assert_predicate BodyRenderer.call(nil), :html_safe?
      end

      test ".call returns an empty safe buffer for blank input" do
        assert_equal "", BodyRenderer.call("   ")
      end

      test ".call renders basic Markdown" do
        html = BodyRenderer.call("Some **bold** and _italic_ text.")

        assert_includes html, "<strong>bold</strong>"
        assert_includes html, "<em>italic</em>"
      end

      test ".call renders links" do
        assert_includes BodyRenderer.call("[a](https://x.test)"), '<a href="https://x.test">a</a>'
      end

      test ".call renders lists" do
        html = BodyRenderer.call("- one\n- two\n")

        assert_includes html, "<ul>"
        assert_includes html, "<li>one</li>"
      end

      test ".call renders tables" do
        assert_includes BodyRenderer.call("A | B\n--- | ---\n1 | 2\n"), "<table>"
      end

      test ".call shifts a level-one heading to h2" do
        # The page title is already the page's h1.
        html = BodyRenderer.call("# Title\n")

        assert_includes html, "<h2>Title</h2>"
        assert_not_includes html, "<h1"
      end

      test ".call shifts h2 to h3 and h3 to h4" do
        html = BodyRenderer.call("## Two\n\n### Three\n")

        assert_includes html, "<h3>Two</h3>"
        assert_includes html, "<h4>Three</h4>"
      end

      test ".call caps the shift at h4" do
        html = BodyRenderer.call("#### Four\n\n##### Five\n\n###### Six\n")

        assert_equal 3, html.scan("<h4>").length
        assert_not_includes html, "<h5"
      end

      test ".call emits no heading anchor links" do
        # commonmarker injects <a href="#slug" class="anchor"></a> into every
        # heading by default. The sanitizer drops class and aria-label but KEEPS
        # href, so without extension: {header_ids: nil} every heading ends up
        # carrying an empty anchor.
        html = BodyRenderer.call("# Title\n")

        assert_not_includes html, "anchor"
        assert_not_includes html, 'href="#'
      end

      test ".call escapes raw HTML in the source" do
        html = BodyRenderer.call("before <script>alert('x')</script> after")

        assert_not_includes html, "<script"
        assert_not_includes html, "alert('x')"
      end

      test ".call strips a disallowed tag but keeps its text" do
        html = BodyRenderer.call("<iframe src='https://evil.test'></iframe>kept")

        assert_not_includes html, "<iframe"
        assert_includes html, "kept"
      end

      test ".call strips a javascript href" do
        assert_not_includes BodyRenderer.call("[x](javascript:alert(1))"), "javascript:"
      end

      test ".call keeps images" do
        html = BodyRenderer.call("![a cover](https://images.test/a.png)")

        assert_includes html, "<img"
        assert_includes html, 'src="https://images.test/a.png"'
        assert_includes html, 'alt="a cover"'
      end

      test ".call returns an html_safe buffer" do
        assert_predicate BodyRenderer.call("hi"), :html_safe?
      end

      test ".call is a pure function of its input" do
        # Rendering is a read-time transform, so calling it twice on the same
        # stored source must give the same answer. This is NOT the same claim as
        # idempotency -- the output is HTML and is never fed back in.
        markdown = "# Title\n\nSome **bold** text and a [link](https://x.test).\n"

        assert_equal BodyRenderer.call(markdown), BodyRenderer.call(markdown)
      end
    end
  end
end
```

- [ ] **Step 7: Run it to verify it fails**

Run: `bin/rails test test/lib/services/news/body_renderer_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::News::BodyRenderer`.

- [ ] **Step 8: Write BodyRenderer**

Create `app/lib/services/news/body_renderer.rb`:

```ruby
module Services
  module News
    # The ONE place a news post's Markdown becomes HTML. Public pages, the RSS
    # feed and the admin preview all go through here, so the preview cannot
    # drift from what visitors see.
    #
    # Nothing writes through this class. NewsPost#body stores the author's
    # Markdown byte-for-byte and this runs on read, which is what makes the
    # "a sanitizer fed its own output" class of bug unrepresentable here --
    # the output is HTML and is never parsed back into the column.
    #
    # Two layers, because they fail differently:
    #   1. commonmarker with unsafe: false escapes raw HTML in the source rather
    #      than emitting it (a <script> becomes an "<!-- raw HTML omitted -->"
    #      comment).
    #   2. SafeListSanitizer enforces an explicit allowlist over the result.
    # Either alone would very likely be enough. Both is cheap.
    class BodyRenderer
      ALLOWED_TAGS = %w[
        p br a em strong del code pre blockquote hr img
        ul ol li h2 h3 h4
        table thead tbody tr th td
      ].freeze

      ALLOWED_ATTRIBUTES = %w[href title src alt].freeze

      # The page title is already the page's <h1>, so a body heading must never
      # be one. Everything at h4 or deeper flattens to h4 rather than
      # disappearing.
      HEADING_SHIFT = {"h1" => "h2", "h2" => "h3", "h3" => "h4"}.freeze
      HEADING_SELECTOR = "h1,h2,h3,h4,h5,h6".freeze

      COMMONMARKER_OPTIONS = {
        render: {unsafe: false},
        # header_ids: nil suppresses commonmarker's default anchor injection.
        # With it on, every heading gets <a href="#slug" class="anchor"></a>;
        # the sanitizer drops class but keeps href, leaving an empty link
        # inside every heading.
        extension: {header_ids: nil, table: true, strikethrough: true, autolink: true}
      }.freeze

      def self.call(markdown) = new(markdown).call

      def initialize(markdown)
        @markdown = markdown
      end

      def call
        return "".html_safe if @markdown.blank?

        fragment = Nokogiri::HTML5.fragment(to_html)
        shift_headings(fragment)
        sanitize(fragment.to_html)
      end

      private

      def to_html
        Commonmarker.to_html(@markdown.to_s, options: COMMONMARKER_OPTIONS)
      end

      # css() returns a snapshot NodeSet and renaming a node adds no nodes, so a
      # single pass cannot double-shift an h1 into h3.
      def shift_headings(fragment)
        fragment.css(HEADING_SELECTOR).each do |node|
          node.name = HEADING_SHIFT.fetch(node.name, "h4")
        end
      end

      def sanitize(html)
        Rails::HTML5::SafeListSanitizer.new
          .sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
          .html_safe
      end
    end
  end
end
```

- [ ] **Step 9: Run both service tests and the model test**

Run: `bin/rails test test/lib/services/news/ test/models/news_post_test.rb`
Expected: PASS. The three `excerpt` tests deferred in Task 2 now pass.

- [ ] **Step 10: Verify the tests are not vacuous**

Remove `extension: {header_ids: nil, ...}` from `COMMONMARKER_OPTIONS`, re-run, confirm "emits no heading anchor links" goes RED. Remove `shift_headings(fragment)`, confirm the three heading tests go RED. Restore both.

- [ ] **Step 11: Run the full suite and commit**

```bash
bin/rails test
# Expected: 7003 + ~35 new runs, 0 failures, 0 errors
bundle exec standardrb --fix app/lib/services/news test/lib/services/news
git add Gemfile Gemfile.lock app/lib/services/news test/lib/services/news
git commit -m "feat(news): add BodyRenderer and PlainText services"
```

---

# Increment 2 — Migration

### Task 5: Legacy models

**Files:**
- Create: `app/models/legacy_books/blog_post.rb`
- Create: `app/models/legacy_books/rich_text.rb`
- Test: `test/models/legacy_books/blog_post_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `LegacyBooks::BlogPost` with `#rich_text_content`, `LegacyBooks::RichText`. Both read-only, on the `legacy_books` connection.

- [ ] **Step 1: Read the existing legacy base class**

Run: `cat app/models/legacy_books/record.rb`
Follow whatever `connects_to` / `readonly` pattern it establishes exactly. Every model below inherits from it.

- [ ] **Step 2: Write the failing test**

Create `test/models/legacy_books/blog_post_test.rb`:

```ruby
require "test_helper"

module LegacyBooks
  class BlogPostTest < ActiveSupport::TestCase
    test "reads from the legacy blog_posts table" do
      assert_equal "blog_posts", BlogPost.table_name
    end

    test "is read only" do
      assert_predicate BlogPost.new, :readonly?
    end

    test "rich_text_content joins on the polymorphic record" do
      sql = BlogPost.new(id: 7).association(:rich_text_content).scope.to_sql

      assert_includes sql, "action_text_rich_texts"
      assert_includes sql, "BlogPost"
      assert_includes sql, "content"
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/models/legacy_books/blog_post_test.rb`
Expected: FAIL with `NameError: uninitialized constant LegacyBooks::BlogPost`.

- [ ] **Step 4: Write the models**

Create `app/models/legacy_books/rich_text.rb`:

```ruby
module LegacyBooks
  # The legacy app's ActionText storage. The new app has no ActionText tables of
  # its own -- this exists only to read the 31 blog post bodies out.
  class RichText < Record
    self.table_name = "action_text_rich_texts"

    belongs_to :record, polymorphic: true
  end
end
```

Create `app/models/legacy_books/blog_post.rb`:

```ruby
module LegacyBooks
  class BlogPost < Record
    self.table_name = "blog_posts"

    # ActionText stores the body under name "content" keyed by the polymorphic
    # record. The legacy class name is "BlogPost", which is what record_type
    # holds -- NOT this namespaced constant.
    has_one :rich_text_content,
      -> { where(name: "content") },
      class_name: "LegacyBooks::RichText",
      foreign_key: :record_id,
      as: :record

    def body_html = rich_text_content&.body
  end
end
```

If `LegacyBooks::Record` does not already force `record_type` to the un-namespaced name, add `self.record_type = "BlogPost"` handling — verify with the SQL assertion in the test, which requires the literal string `BlogPost` (not `LegacyBooks::BlogPost`) in the query.

- [ ] **Step 5: Run it to verify it passes**

Run: `bin/rails test test/models/legacy_books/blog_post_test.rb`
Expected: PASS, 3 runs.

- [ ] **Step 6: Sanity check against the real legacy database**

```bash
bin/rails runner 'p LegacyBooks::BlogPost.count; p LegacyBooks::BlogPost.order(:id).first.body_html&.first(80)'
```
Expected: `31` and a string beginning `"<div>"`. If the count is not 31, stop and report — the plan's arithmetic assumes 31.

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb --fix app/models/legacy_books test/models/legacy_books
git add app/models/legacy_books test/models/legacy_books
git commit -m "feat(news): add legacy blog_posts read models"
```

---

### Task 6: NewsBodyConverter

**Files:**
- Modify: `Gemfile`
- Create: `app/lib/services/books_migration/news_body_converter.rb`
- Test: `test/lib/services/books_migration/news_body_converter_test.rb`

**Interfaces:**
- Consumes: `Services::News::BodyRenderer`, `Services::News::PlainText`.
- Produces:
  - `Services::BooksMigration::NewsBodyConverter.call(html) → String` (Markdown)
  - `Services::BooksMigration::NewsBodyConverter.round_trips?(html) → Boolean`

- [ ] **Step 1: Add the gem**

Add to `Gemfile`:

```ruby
# HTML -> Markdown, needed only for the one-time legacy blog migration.
# Removable once the production run is done.
gem "reverse_markdown", "~> 3.0"
```

Run: `bundle install`

- [ ] **Step 2: Write the failing test**

Create `test/lib/services/books_migration/news_body_converter_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class NewsBodyConverterTest < ActiveSupport::TestCase
      test ".call converts a Trix div to a paragraph" do
        assert_equal "one\n\ntwo", NewsBodyConverter.call("<div>one</div><div>two</div>").strip
      end

      test ".call converts strong to bold" do
        assert_includes NewsBodyConverter.call("<div><strong>hi</strong></div>"), "**hi**"
      end

      test ".call converts links" do
        html = '<div><a href="https://x.test">label</a></div>'

        assert_includes NewsBodyConverter.call(html), "[label](https://x.test)"
      end

      test ".call converts ordered lists" do
        assert_includes NewsBodyConverter.call("<ol><li>a</li><li>b</li></ol>"), "1. a"
      end

      test ".call removes the stray space reverse_markdown inserts before punctuation" do
        # reverse_markdown turns "<strong>x</strong>:" into "**x** :", which
        # renders visibly wrong. Measured: this affects 2 of the 31 real posts.
        assert_includes NewsBodyConverter.call("<div><strong>top 5</strong>:</div>"), "**top 5**:"
        assert_not_includes NewsBodyConverter.call("<div><strong>top 5</strong>:</div>"), "** :"
      end

      test ".call leaves a legitimate space before a colon alone" do
        assert_includes NewsBodyConverter.call("<div>a word : spaced</div>"), "a word : spaced"
      end

      test ".round_trips? is true when the rendered Markdown carries the same text" do
        assert NewsBodyConverter.round_trips?("<div>one</div><div>two</div>")
      end

      test ".round_trips? compares block-aware text on both sides" do
        # A legacy <div>-per-paragraph body renders back as <p>-per-paragraph.
        # Comparing raw .text would report a mismatch on every multi-block post.
        assert NewsBodyConverter.round_trips?("<div>alpha</div><div>beta</div>")
      end

      test ".round_trips? is false when text is lost" do
        NewsBodyConverter.stubs(:call).returns("only the first bit")

        assert_not NewsBodyConverter.round_trips?("<div>only the first bit</div><div>and more</div>")
      end
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/news_body_converter_test.rb`
Expected: FAIL with `NameError: uninitialized constant ...NewsBodyConverter`.

- [ ] **Step 4: Write the converter**

Create `app/lib/services/books_migration/news_body_converter.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy ActionText (Trix) HTML -> Markdown, for the one-time blog migration.
    #
    # The whole legacy corpus is eight tags -- a, br, strong, h1, ul, ol, li,
    # div -- comfortably inside what reverse_markdown handles. Measured against
    # all 31 real posts, .call plus .round_trips? gives 31/31 text-identical.
    #
    # Root-anchored ::Services below is not needed because News is not nested
    # under BooksMigration, but note that a bare `Books::` inside this module
    # would resolve to Services::BooksMigration::Books and raise. Root-anchor
    # anything in the Books namespace.
    class NewsBodyConverter
      # reverse_markdown emits "**bold** :" for "<strong>bold</strong>:" -- it
      # inserts a space after a closing inline marker when punctuation follows
      # immediately. Narrowly targeted: only a marker directly followed by
      # " " + punctuation, so "a word : spaced" in ordinary prose is untouched.
      STRAY_SPACE = /(\*\*|\*|_|`) ([:;,.!?])/

      def self.call(html)
        return "" if html.blank?

        markdown = ReverseMarkdown.convert(
          html.to_s,
          unknown_tags: :bypass,
          github_flavored: true
        )

        markdown.gsub(STRAY_SPACE, '\1\2')
      end

      # Renders the produced Markdown back to HTML through the very renderer the
      # public page uses, and compares block-aware plain text against the legacy
      # HTML's. Catches content silently dropped by the conversion.
      #
      # Both sides go through Services::News::PlainText, which inserts a
      # separator at block boundaries -- comparing raw .text would flag every
      # multi-block post, because legacy wraps paragraphs in <div> and the
      # renderer emits <p>.
      def self.round_trips?(html)
        legacy = ::Services::News::PlainText.call(html)
        rendered = ::Services::News::PlainText.call(
          ::Services::News::BodyRenderer.call(call(html))
        )

        legacy == rendered
      end
    end
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/news_body_converter_test.rb`
Expected: PASS, 9 runs.

- [ ] **Step 6: Prove it against all 31 real posts**

```bash
bin/rails runner '
ok, bad = 0, []
LegacyBooks::BlogPost.order(:id).each do |p|
  html = p.body_html
  Services::BooksMigration::NewsBodyConverter.round_trips?(html) ? ok += 1 : bad << p.id
end
puts "round-trips: #{ok}/#{LegacyBooks::BlogPost.count}"
puts "failing ids: #{bad.inspect}" if bad.any?
'
```
Expected: `round-trips: 31/31`. If any post fails, STOP and report the ids — do not proceed to Task 7.

- [ ] **Step 7: Verify the tests are not vacuous**

Remove the `.gsub(STRAY_SPACE, ...)` line, re-run the unit test, confirm "removes the stray space" goes RED and Step 6 drops to 29/31. Restore it.

- [ ] **Step 8: Commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/news_body_converter.rb test/lib/services/books_migration/news_body_converter_test.rb
git add Gemfile Gemfile.lock app/lib/services/books_migration/news_body_converter.rb test/lib/services/books_migration/news_body_converter_test.rb
git commit -m "feat(news): add legacy HTML to Markdown converter"
```

---

### Task 7: NewsPostMigrator and rake task

**Files:**
- Create: `app/lib/services/books_migration/news_post_migrator.rb`
- Modify: `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/news_post_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyBooks::BlogPost`, `NewsBodyConverter`, `NewsPost`.
- Produces: `Services::BooksMigration::NewsPostMigrator.call → Result` with `data: {created:, skipped:, round_trip_failures: [ids]}`. Rake task `data_migration:news_posts`.

- [ ] **Step 1: Read a sibling migrator for the house Result shape**

Run: `sed -n '1,60p' app/lib/services/books_migration/donation_migrator.rb`
Match its `Result` struct, its logging, and its idempotency approach exactly.

- [ ] **Step 2: Write the failing test**

Create `test/lib/services/books_migration/news_post_migrator_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class NewsPostMigratorTest < ActiveSupport::TestCase
      def legacy_post(id:, title:, slug:, created_at: 2.years.ago)
        stub(
          id: id,
          title: title,
          slug: slug,
          created_at: created_at,
          updated_at: created_at,
          user_id: users(:admin_user).id,
          body_html: "<div>Body of #{title}</div>"
        )
      end

      test "creates a books news post per legacy post" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Welcome", slug: "welcome")
        ])

        assert_difference -> { ::NewsPost.books.count }, 1 do
          NewsPostMigrator.call
        end

        post = ::NewsPost.books.find_by(slug: "welcome")
        assert_equal "Welcome", post.title
        assert_equal users(:admin_user).id, post.user_id
      end

      test "preserves the legacy slug verbatim, including a collision suffix" do
        weird = "added-5-new-lists-d0171449-5fc7-4e93-b5ea-81e3fac28ce3"
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 12, title: "Added 5 new lists", slug: weird)
        ])

        NewsPostMigrator.call

        assert ::NewsPost.books.exists?(slug: weird)
      end

      test "sets published_at from the legacy created_at" do
        created = Time.zone.parse("2024-05-09 03:48:34")
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 11, title: "300 Lists!", slug: "300-lists", created_at: created)
        ])

        NewsPostMigrator.call

        assert_equal created, ::NewsPost.books.find_by(slug: "300-lists").published_at
      end

      test "stores Markdown, not HTML" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          stub(id: 1, title: "T", slug: "t", created_at: 1.year.ago, updated_at: 1.year.ago,
            user_id: users(:admin_user).id, body_html: "<div><strong>bold</strong></div>")
        ])

        NewsPostMigrator.call

        body = ::NewsPost.books.find_by(slug: "t").body
        assert_includes body, "**bold**"
        assert_not_includes body, "<strong>"
      end

      test "is idempotent -- a second run creates nothing" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Welcome", slug: "welcome")
        ])
        NewsPostMigrator.call

        assert_no_difference -> { ::NewsPost.count } do
          NewsPostMigrator.call
        end
      end

      test "reports round-trip failures without aborting the run" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Good", slug: "good"),
          legacy_post(id: 2, title: "Bad", slug: "bad")
        ])
        NewsBodyConverter.stubs(:round_trips?).returns(true).then.returns(false)

        result = NewsPostMigrator.call

        assert result.success?
        assert_equal [2], result.data[:round_trip_failures]
        assert_equal 2, result.data[:created]
      end

      test "does not migrate the tags, pinned or front_page columns" do
        # They are dropped on purpose: tags is empty on all 31, pinned is false
        # on all 31, and front_page is read by no legacy code.
        assert_not ::NewsPost.column_names.include?("tags")
        assert_not ::NewsPost.column_names.include?("pinned")
        assert_not ::NewsPost.column_names.include?("front_page")
      end
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/news_post_migrator_test.rb`
Expected: FAIL with `NameError: uninitialized constant ...NewsPostMigrator`.

- [ ] **Step 4: Write the migrator**

Create `app/lib/services/books_migration/news_post_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy blog_posts -> news_posts, domain :books. One-time lift.
    #
    # Dropped on purpose, each verified against the real corpus:
    #   front_page -- true on 27 of 31 and read by NO legacy code
    #   pinned     -- false on all 31
    #   tags       -- empty on all 31; news_topics replaces it
    #   Blog       -- one row, titled "Default", whose only job was to be a parent
    #
    # Topics are NOT assigned here. There is no legacy source for them, and
    # guessing from title keywords is not worth the code on a 31-row job that
    # gets reviewed by hand anyway.
    #
    # Idempotent by slug: re-running skips posts already present. Deliberately
    # NOT a re-sync -- it will not update a post whose body has been edited in
    # admin since the last run.
    class NewsPostMigrator
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        created = 0
        skipped = 0
        round_trip_failures = []

        ::LegacyBooks::BlogPost.order(:id).each do |legacy|
          if ::NewsPost.books.exists?(slug: legacy.slug)
            skipped += 1
            next
          end

          html = legacy.body_html
          round_trip_failures << legacy.id unless NewsBodyConverter.round_trips?(html)

          ::NewsPost.create!(
            domain: :books,
            title: legacy.title,
            # Assigned directly so friendly_id leaves it alone. The legacy slug
            # is a live public URL -- including the one UUID-suffixed collision
            # slug -- and regenerating it from the title would break it.
            slug: legacy.slug,
            body: NewsBodyConverter.call(html),
            published_at: legacy.created_at,
            created_at: legacy.created_at,
            updated_at: legacy.updated_at,
            user_id: legacy.user_id
          )
          created += 1
        end

        Result.new(
          success?: true,
          data: {created:, skipped:, round_trip_failures:},
          errors: []
        )
      end
    end
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/news_post_migrator_test.rb`
Expected: PASS, 7 runs.

- [ ] **Step 6: Add the rake task**

Append to the `data_migration` namespace in `lib/tasks/data_migration.rake`, matching the surrounding style:

```ruby
desc "Migrate legacy blog_posts into news_posts (domain :books; preserves slugs + dates)"
task news_posts: :environment do
  pp Services::BooksMigration::NewsPostMigrator.call
end
```

- [ ] **Step 7: Add a before/after dump task**

Append alongside it:

```ruby
desc "Dump legacy blog HTML next to its converted Markdown for hand review"
task news_posts_diff: :environment do
  path = Rails.root.join("tmp", "news_posts_conversion.txt")
  File.open(path, "w") do |f|
    LegacyBooks::BlogPost.order(:id).each do |p|
      html = p.body_html
      f.puts "=" * 78
      f.puts "##{p.id}  #{p.title}  (#{p.slug})"
      f.puts "round-trips: #{Services::BooksMigration::NewsBodyConverter.round_trips?(html)}"
      f.puts "-" * 30 + " LEGACY HTML " + "-" * 30
      f.puts html
      f.puts "-" * 30 + " MARKDOWN " + "-" * 33
      f.puts Services::BooksMigration::NewsBodyConverter.call(html)
      f.puts
    end
  end
  puts "wrote #{path}"
end
```

- [ ] **Step 8: Run the full suite and commit**

```bash
bin/rails test
bundle exec standardrb --fix app/lib/services/books_migration lib/tasks/data_migration.rake test/lib/services/books_migration
git add app/lib/services/books_migration/news_post_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/news_post_migrator_test.rb
git commit -m "feat(news): add legacy blog post migrator and rake tasks"
```

---

### Task 8: Development migration run and hand review

**Files:** none — this is a verification task with a human gate.

- [ ] **Step 1: Snapshot the development database**

```bash
cd web-app
bin/snapshot-dev-db.sh --label pre-news-migration
```
Do not skip this. Books data exists only in development and takes hours to rebuild.

- [ ] **Step 2: Generate the review file**

```bash
bin/rails data_migration:news_posts_diff
```
Expected: `wrote .../tmp/news_posts_conversion.txt`, and every entry reading `round-trips: true`.

- [ ] **Step 3: Confirm 31/31 round-trip**

```bash
grep -c "round-trips: true" tmp/news_posts_conversion.txt
grep -n "round-trips: false" tmp/news_posts_conversion.txt
```
Expected: `31`, and no output from the second command. If any post reports false, STOP and report which.

- [ ] **Step 4: Run the migration**

```bash
bin/rails data_migration:news_posts
```
Expected: `created: 31, skipped: 0, round_trip_failures: []`.

- [ ] **Step 5: Verify the result**

```bash
bin/rails runner '
puts "posts: #{NewsPost.books.count}"
puts "published: #{NewsPost.books.published.count}"
puts "authors: #{NewsPost.books.distinct.pluck(:user_id).inspect}"
puts "bodies containing a raw HTML tag: #{NewsPost.books.where("body ~ ?", "<[a-z]+[ >]").count}"
puts "newest: #{NewsPost.books.published.recent.first.title}"
'
```
Expected: 31 posts, 31 published, authors `[1141]`, **0** bodies containing a raw HTML tag, newest `December Update`.

- [ ] **Step 6: STOP — hand review gate**

Present `tmp/news_posts_conversion.txt` to the owner and ask them to read all 31 conversions. Average body is ~500 characters. The round-trip check proves no text was lost; only a human catches spacing that is technically valid and reads wrong. **Do not proceed to Increment 3 until they confirm.**

- [ ] **Step 7: Verify idempotency**

```bash
bin/rails data_migration:news_posts
```
Expected: `created: 0, skipped: 31`.

- [ ] **Step 8: Commit nothing, record the outcome**

No code changed. Note the run in the PR description when the branch is finished.

---

# Increment 3 — Books admin

### Task 9: Admin topics CRUD

**Files:**
- Create: `app/controllers/admin/news_topics_base_controller.rb`
- Create: `app/controllers/admin/books/news_topics_controller.rb`
- Create: `app/views/admin/news_topics/{index,new,edit,_form}.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/lib/admin/domain_nav.rb`
- Test: `test/controllers/admin/books/news_topics_controller_test.rb`

**Interfaces:**
- Consumes: `NewsTopic`.
- Produces: `Admin::NewsTopicsBaseController` with private hooks `news_domain`, `news_topics_path_for(params = {})`, `new_news_topic_path_for`, `edit_news_topic_path_for(topic)`. Route helpers `admin_books_news_topics_path`, `new_admin_books_news_topic_path`, `edit_admin_books_news_topic_path`.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the books domain constraint's `namespace :admin, module: "admin/books", as: "admin_books"` block, alongside the existing `resources :authors`:

```ruby
resources :news_topics
resources :news_posts
```

- [ ] **Step 2: Add the sidebar entry**

In `app/lib/admin/domain_nav.rb`, add to `CONFIGS[:books][:items]`, after the Reviews entry:

```ruby
{label: "News", icon: :chat, path: -> { URL_HELPERS.admin_books_news_posts_path }},
{label: "News Topics", icon: :category, path: -> { URL_HELPERS.admin_books_news_topics_path }},
```

- [ ] **Step 3: Write the failing test**

Create `test/controllers/admin/books/news_topics_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class NewsTopicsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev-new.thegreatestbooks.org"
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index lists only this domain's topics" do
        get admin_books_news_topics_path

        assert_response :success
        assert_equal(
          NewsTopic.books.sorted_by_name.pluck(:id),
          @controller.view_assigns["news_topics"].map(&:id)
        )
      end

      test "index does not list another domain's topics" do
        get admin_books_news_topics_path

        assert_not_includes @controller.view_assigns["news_topics"].map(&:id),
          news_topics(:music_site_news).id
      end

      test "create makes a topic in this domain" do
        assert_difference -> { NewsTopic.books.count }, 1 do
          post admin_books_news_topics_path, params: {news_topic: {name: "Data Updates"}}
        end

        assert_equal "data-updates", NewsTopic.books.order(:id).last.slug
      end

      test "create re-renders the form on a validation failure" do
        post admin_books_news_topics_path, params: {news_topic: {name: ""}}

        assert_response :unprocessable_entity
      end

      test "update renames without moving the slug" do
        topic = news_topics(:books_rankings)

        patch admin_books_news_topic_path(topic), params: {news_topic: {name: "Ranking News"}}

        assert_equal "Ranking News", topic.reload.name
        assert_equal "rankings", topic.slug
      end

      test "destroy removes the topic" do
        assert_difference -> { NewsTopic.books.count }, -1 do
          delete admin_books_news_topic_path(news_topics(:books_feature_launch))
        end
      end

      test "a signed-out visitor is turned away" do
        reset!
        host! "dev-new.thegreatestbooks.org"

        get admin_books_news_topics_path

        assert_redirected_to "/"
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bin/rails test test/controllers/admin/books/news_topics_controller_test.rb`
Expected: FAIL — routing error, then missing controller.

- [ ] **Step 5: Write the base controller**

Create `app/controllers/admin/news_topics_base_controller.rb`:

```ruby
# Domain-agnostic topic CRUD. Each domain supplies a routable subclass that
# fills in news_domain and the path helpers and mixes in
# Admin::DomainScopedAuth itself, because admin auth is domain-scoped through
# that concern. Mirrors Admin::ReviewsBaseController.
#
# Path helper methods are named *_for rather than matching the route helper
# names: a private method named admin_books_news_topics_path would shadow the
# real helper in the views this controller renders.
class Admin::NewsTopicsBaseController < Admin::BaseController
  before_action :require_domain_write!, only: [:create, :update, :destroy]
  before_action :set_news_topic, only: [:edit, :update, :destroy]

  helper_method :news_topics_path_for, :news_topic_path_for, :new_news_topic_path_for,
    :edit_news_topic_path_for

  def index
    @news_topics = scope.sorted_by_name
  end

  def new
    @news_topic = NewsTopic.new(domain: news_domain)
  end

  def create
    @news_topic = NewsTopic.new(news_topic_params.merge(domain: news_domain))

    if @news_topic.save
      redirect_to news_topics_path_for, notice: "Topic created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @news_topic.update(news_topic_params)
      redirect_to news_topics_path_for, notice: "Topic updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @news_topic.destroy!
    redirect_to news_topics_path_for, notice: "Topic deleted."
  end

  private

  # Always scoped, never a bare NewsTopic.find: authenticate_admin! only proves
  # access to the domain this controller is MOUNTED under, and says nothing
  # about which domain the id in the URL belongs to.
  def scope = NewsTopic.where(domain: news_domain)

  def set_news_topic
    @news_topic = scope.friendly.find(params[:id])
  end

  def news_topic_params
    params.require(:news_topic).permit(:name)
  end
end
```

- [ ] **Step 6: Write the books subclass**

Create `app/controllers/admin/books/news_topics_controller.rb`:

```ruby
class Admin::Books::NewsTopicsController < Admin::NewsTopicsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :books

  def news_topics_path_for(params = {}) = admin_books_news_topics_path(params)

  def news_topic_path_for(topic) = admin_books_news_topic_path(topic)

  def new_news_topic_path_for = new_admin_books_news_topic_path

  def edit_news_topic_path_for(topic) = edit_admin_books_news_topic_path(topic)
end
```

- [ ] **Step 7: Write the views**

Create `app/views/admin/news_topics/index.html.erb`:

```erb
<% content_for :title, "News Topics" %>

<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold">News Topics</h1>
  <%= link_to "New Topic", new_news_topic_path_for, class: "btn btn-primary" %>
</div>

<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <% if @news_topics.any? %>
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Slug</th>
              <th>Posts</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <% @news_topics.each do |topic| %>
              <tr>
                <td class="font-semibold"><%= topic.name %></td>
                <td class="font-mono text-sm"><%= topic.slug %></td>
                <td><%= topic.news_posts.size %></td>
                <td class="text-right">
                  <%= link_to "Edit", edit_news_topic_path_for(topic), class: "btn btn-sm btn-ghost" %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% else %>
      <p class="text-base-content/70">No topics yet.</p>
    <% end %>
  </div>
</div>
```

Create `app/views/admin/news_topics/_form.html.erb`:

```erb
<%= form_with model: @news_topic,
      url: (@news_topic.persisted? ? news_topic_path_for(@news_topic) : news_topics_path_for),
      class: "space-y-6" do |f| %>
  <% if @news_topic.errors.any? %>
    <div class="alert alert-error">
      <div>
        <h3 class="font-bold"><%= pluralize(@news_topic.errors.count, "error") %> prohibited this topic from being saved:</h3>
        <ul class="list-disc list-inside mt-2">
          <% @news_topic.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <div>
        <%= f.label :name, class: "label" do %>
          <span class="font-semibold">Name <span class="text-error">*</span></span>
        <% end %>
        <%= f.text_field :name,
              class: "input w-full #{"input-error" if @news_topic.errors[:name].any?}",
              placeholder: "Rankings",
              required: true,
              autofocus: true %>
        <% if @news_topic.persisted? %>
          <p class="text-sm text-base-content/70 mt-1">
            URL stays <span class="font-mono">/news/topic/<%= @news_topic.slug %></span> — renaming does not move it.
          </p>
        <% end %>
      </div>
    </div>
  </div>

  <div class="flex gap-2">
    <%= f.submit(@news_topic.persisted? ? "Save Topic" : "Create Topic", class: "btn btn-primary") %>
    <%= link_to "Cancel", news_topics_path_for, class: "btn btn-ghost" %>
  </div>
<% end %>
```

Create `app/views/admin/news_topics/new.html.erb`:

```erb
<% content_for :title, "New News Topic" %>
<h1 class="text-2xl font-bold mb-6">New Topic</h1>
<%= render "form" %>
```

Create `app/views/admin/news_topics/edit.html.erb`:

```erb
<% content_for :title, "Edit News Topic" %>
<h1 class="text-2xl font-bold mb-6">Edit Topic</h1>
<%= render "form" %>
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/controllers/admin/books/news_topics_controller_test.rb`
Expected: PASS, 7 runs.

- [ ] **Step 9: Verify the tests are not vacuous**

Change `scope` to `NewsTopic.all`, re-run, confirm "index does not list another domain's topics" goes RED. Restore.

- [ ] **Step 10: Run the daisyUI guard, lint, commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/admin config/routes.rb app/lib/admin/domain_nav.rb test/controllers/admin
git add app/controllers/admin/news_topics_base_controller.rb app/controllers/admin/books/news_topics_controller.rb app/views/admin/news_topics config/routes.rb app/lib/admin/domain_nav.rb test/controllers/admin/books/news_topics_controller_test.rb
git commit -m "feat(news): add admin news topics CRUD for books"
```

---

### Task 10: Admin posts index and show

**Files:**
- Create: `app/controllers/admin/news_posts_base_controller.rb`
- Create: `app/controllers/admin/books/news_posts_controller.rb`
- Create: `app/views/admin/news_posts/{index,show}.html.erb`
- Test: `test/controllers/admin/books/news_posts_controller_test.rb`

**Interfaces:**
- Consumes: `NewsPost`, `NewsTopic`.
- Produces: `Admin::NewsPostsBaseController` with hooks `news_domain`, `news_posts_path_for`, `news_post_path_for(post)`, `new_news_post_path_for`, `edit_news_post_path_for(post)`, `preview_news_posts_path_for`.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/admin/books/news_posts_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class NewsPostsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev-new.thegreatestbooks.org"
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index lists this domain's posts, drafts included" do
        get admin_books_news_posts_path

        assert_response :success
        ids = @controller.view_assigns["news_posts"].map(&:id)
        assert_includes ids, news_posts(:books_december_update).id
        assert_includes ids, news_posts(:books_draft).id
      end

      test "index excludes another domain's posts" do
        get admin_books_news_posts_path

        assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
          news_posts(:music_launch).id
      end

      test "index orders newest first with drafts at the top" do
        ids = (get admin_books_news_posts_path) &&
          @controller.view_assigns["news_posts"].map(&:id)

        assert_equal news_posts(:books_draft).id, ids.first
      end

      test "show renders a post" do
        get admin_books_news_post_path(news_posts(:books_december_update))

        assert_response :success
        assert_select "h1", text: /December Update/
      end

      test "show renders a draft" do
        get admin_books_news_post_path(news_posts(:books_draft))

        assert_response :success
      end

      test "show 404s for another domain's post" do
        assert_raises(ActiveRecord::RecordNotFound) do
          get admin_books_news_post_path(news_posts(:music_launch))
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: FAIL — missing controller.

- [ ] **Step 3: Write the base controller (index and show only for now)**

Create `app/controllers/admin/news_posts_base_controller.rb`:

```ruby
# Domain-agnostic news post CRUD plus the Markdown preview. Each domain
# supplies a routable subclass filling in news_domain and the path helpers, and
# mixing in Admin::DomainScopedAuth itself. Mirrors Admin::ReviewsBaseController.
class Admin::NewsPostsBaseController < Admin::BaseController
  before_action :require_domain_write!, only: [:create, :update, :destroy, :preview]
  before_action :set_news_post, only: [:show, :edit, :update, :destroy]

  helper_method :news_posts_path_for, :news_post_path_for, :new_news_post_path_for,
    :edit_news_post_path_for, :preview_news_posts_path_for

  def index
    # Drafts first, then newest published. NULLS FIRST is explicit: Postgres
    # sorts NULLs last under DESC by default, which would bury the drafts you
    # are most likely to be looking for at the bottom of the list.
    @news_posts = scope
      .includes(:user, :news_topics)
      .order(Arel.sql("published_at DESC NULLS FIRST, id DESC"))
  end

  def show
  end

  private

  # Always scoped, never a bare NewsPost.find: authenticate_admin! proves access
  # to the domain this controller is MOUNTED under, not that the id in the URL
  # belongs to it.
  def scope = NewsPost.where(domain: news_domain)

  def set_news_post
    @news_post = scope.friendly.find(params[:id])
  end
end
```

- [ ] **Step 4: Write the books subclass**

Create `app/controllers/admin/books/news_posts_controller.rb`:

```ruby
class Admin::Books::NewsPostsController < Admin::NewsPostsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :books

  def news_posts_path_for(params = {}) = admin_books_news_posts_path(params)

  def news_post_path_for(post) = admin_books_news_post_path(post)

  def new_news_post_path_for = new_admin_books_news_post_path

  def edit_news_post_path_for(post) = edit_admin_books_news_post_path(post)

  def preview_news_posts_path_for = preview_admin_books_news_posts_path
end
```

- [ ] **Step 5: Add the preview route**

In `config/routes.rb`, change the books admin `resources :news_posts` to:

```ruby
resources :news_posts do
  collection do
    post :preview
  end
end
```

- [ ] **Step 6: Write the index view**

Create `app/views/admin/news_posts/index.html.erb`:

```erb
<% content_for :title, "News" %>

<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold">News</h1>
  <%= link_to "New Post", new_news_post_path_for, class: "btn btn-primary" %>
</div>

<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <% if @news_posts.any? %>
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Title</th>
              <th>Status</th>
              <th>Topics</th>
              <th>Author</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <% @news_posts.each do |post| %>
              <tr>
                <td class="font-semibold">
                  <%= link_to post.title, news_post_path_for(post), class: "link" %>
                </td>
                <td>
                  <%# Status is stated in words, never colour alone. %>
                  <% if post.published? %>
                    <span class="badge badge-success">Published</span>
                    <div class="text-xs text-base-content/70 mt-1">
                      <%= post.published_at.strftime("%b %-d, %Y") %>
                    </div>
                  <% elsif post.published_at.present? %>
                    <span class="badge badge-warning">Scheduled</span>
                    <div class="text-xs text-base-content/70 mt-1">
                      <%= post.published_at.strftime("%b %-d, %Y") %>
                    </div>
                  <% else %>
                    <span class="badge badge-ghost">Draft</span>
                  <% end %>
                </td>
                <td>
                  <% post.news_topics.each do |topic| %>
                    <span class="badge badge-outline"><%= topic.name %></span>
                  <% end %>
                </td>
                <td class="text-sm"><%= post.user.email %></td>
                <td class="text-right">
                  <%= link_to "Edit", edit_news_post_path_for(post), class: "btn btn-sm btn-ghost" %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% else %>
      <p class="text-base-content/70">No posts yet.</p>
    <% end %>
  </div>
</div>
```

- [ ] **Step 7: Write the show view**

Create `app/views/admin/news_posts/show.html.erb`:

```erb
<% content_for :title, @news_post.title %>

<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold"><%= @news_post.title %></h1>
  <div class="flex gap-2">
    <%= link_to "Edit", edit_news_post_path_for(@news_post), class: "btn btn-primary" %>
    <%= link_to "All Posts", news_posts_path_for, class: "btn btn-ghost" %>
  </div>
</div>

<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <dl class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-6">
      <div>
        <dt class="text-sm text-base-content/70">Status</dt>
        <dd class="font-semibold"><%= @news_post.published? ? "Published" : (@news_post.published_at ? "Scheduled" : "Draft") %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Publish date</dt>
        <dd class="font-semibold"><%= @news_post.published_at&.strftime("%b %-d, %Y at %H:%M") || "—" %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">URL</dt>
        <dd class="font-mono text-sm">/news/<%= @news_post.slug %></dd>
      </div>
    </dl>

    <%# Rendered through the same BodyRenderer the public page uses. %>
    <div class="prose max-w-none [overflow-wrap:anywhere]">
      <%= Services::News::BodyRenderer.call(@news_post.body) %>
    </div>
  </div>
</div>
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 9: Verify the tests are not vacuous**

Change `scope` to `NewsPost.all`, re-run, confirm "index excludes another domain's posts" and "show 404s" both go RED. Restore.

- [ ] **Step 10: Lint, guard, commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/admin config/routes.rb test/controllers/admin
git add app/controllers/admin/news_posts_base_controller.rb app/controllers/admin/books/news_posts_controller.rb app/views/admin/news_posts config/routes.rb test/controllers/admin/books/news_posts_controller_test.rb
git commit -m "feat(news): add admin news post index and show for books"
```

---

### Task 11: Admin post form

**Files:**
- Modify: `app/controllers/admin/news_posts_base_controller.rb`
- Create: `app/views/admin/news_posts/{new,edit,_form}.html.erb`
- Test: `test/controllers/admin/books/news_posts_controller_test.rb` (extend)

**Interfaces:**
- Consumes: Task 10's base controller.
- Produces: `new`, `create`, `edit`, `update`, `destroy` actions; `news_post_params` permitting `:title, :body, :summary, :published_at, :share_image, {news_topic_ids: []}, {body_images: []}`.

- [ ] **Step 1: Write the failing tests**

Append inside `Admin::Books::NewsPostsControllerTest`:

```ruby
test "create makes a draft when no publish date is given" do
  assert_difference -> { NewsPost.books.count }, 1 do
    post admin_books_news_posts_path, params: {
      news_post: {title: "Brand New", body: "Hello **world**.", published_at: ""}
    }
  end

  created = NewsPost.books.find_by(slug: "brand-new")
  assert_nil created.published_at
  assert_predicate created, :draft?
  assert_equal users(:admin_user).id, created.user_id
end

test "create stores the body exactly as typed" do
  markdown = "# Heading\n\nSome **bold** text.\n"

  post admin_books_news_posts_path, params: {news_post: {title: "Verbatim", body: markdown}}

  assert_equal markdown, NewsPost.books.find_by(slug: "verbatim").body
end

test "create attaches the selected topics" do
  post admin_books_news_posts_path, params: {
    news_post: {
      title: "Tagged", body: "x",
      news_topic_ids: [news_topics(:books_rankings).id, news_topics(:books_new_lists).id]
    }
  }

  assert_equal [news_topics(:books_new_lists).id, news_topics(:books_rankings).id].sort,
    NewsPost.books.find_by(slug: "tagged").news_topic_ids.sort
end

test "create refuses a topic belonging to another domain" do
  post admin_books_news_posts_path, params: {
    news_post: {title: "Cross", body: "x", news_topic_ids: [news_topics(:music_site_news).id]}
  }

  assert_empty NewsPost.books.find_by(slug: "cross").news_topic_ids
end

test "create re-renders the form with the body intact on a validation failure" do
  post admin_books_news_posts_path, params: {news_post: {title: "", body: "kept text"}}

  assert_response :unprocessable_entity
  assert_includes response.body, "kept text"
end

test "update publishes by setting a date" do
  draft = news_posts(:books_draft)

  patch admin_books_news_post_path(draft), params: {
    news_post: {title: draft.title, body: draft.body, published_at: 1.minute.ago.to_fs(:db)}
  }

  assert_predicate draft.reload, :published?
end

test "update does not move the slug when the title changes" do
  post_record = news_posts(:books_december_update)

  patch admin_books_news_post_path(post_record), params: {
    news_post: {title: "December Update Revised", body: post_record.body}
  }

  assert_equal "december-update", post_record.reload.slug
end

test "destroy removes the post" do
  assert_difference -> { NewsPost.books.count }, -1 do
    delete admin_books_news_post_path(news_posts(:books_draft))
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: FAIL — `new`, `create`, `edit`, `update`, `destroy` are not defined.

- [ ] **Step 3: Add the actions**

In `app/controllers/admin/news_posts_base_controller.rb`, add above `private`:

```ruby
def new
  @news_post = NewsPost.new(domain: news_domain)
end

def create
  @news_post = NewsPost.new(news_post_params)
  @news_post.domain = news_domain
  @news_post.user = current_user

  if @news_post.save
    redirect_to news_post_path_for(@news_post), notice: "Post created."
  else
    render :new, status: :unprocessable_entity
  end
end

def edit
end

def update
  if @news_post.update(news_post_params)
    redirect_to news_post_path_for(@news_post), notice: "Post updated."
  else
    render :edit, status: :unprocessable_entity
  end
end

def destroy
  @news_post.destroy!
  redirect_to news_posts_path_for, notice: "Post deleted."
end
```

And in the private section:

```ruby
def available_topics = NewsTopic.where(domain: news_domain).sorted_by_name
helper_method :available_topics

def news_post_params
  permitted = params.require(:news_post).permit(
    :title, :body, :summary, :published_at, :share_image,
    news_topic_ids: [], body_images: []
  )

  # Topic ids arrive from a checkbox list, so a hand-crafted request could name
  # another domain's topic. Intersect with this domain's own rather than trusting
  # the submitted ids -- the join carries no domain of its own to validate against.
  if permitted.key?(:news_topic_ids)
    permitted[:news_topic_ids] = available_topics
      .where(id: permitted[:news_topic_ids].compact_blank)
      .pluck(:id)
  end

  permitted
end
```

- [ ] **Step 4: Write the form**

Create `app/views/admin/news_posts/_form.html.erb`:

```erb
<%= form_with model: @news_post,
      url: (@news_post.persisted? ? news_post_path_for(@news_post) : news_posts_path_for),
      class: "space-y-6" do |f| %>
  <% if @news_post.errors.any? %>
    <div class="alert alert-error">
      <div>
        <h3 class="font-bold"><%= pluralize(@news_post.errors.count, "error") %> prohibited this post from being saved:</h3>
        <ul class="list-disc list-inside mt-2">
          <% @news_post.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body space-y-4">
      <div>
        <%= f.label :title, class: "label" do %>
          <span class="font-semibold">Title <span class="text-error">*</span></span>
        <% end %>
        <%= f.text_field :title,
              class: "input w-full #{"input-error" if @news_post.errors[:title].any?}",
              required: true, autofocus: true %>
        <% if @news_post.persisted? %>
          <p class="text-sm text-base-content/70 mt-1">
            URL stays <span class="font-mono">/news/<%= @news_post.slug %></span> — retitling does not move it.
          </p>
        <% end %>
      </div>

      <div>
        <%= f.label :body, class: "label" do %>
          <span class="font-semibold">Body <span class="text-error">*</span></span>
        <% end %>
        <p class="text-sm text-base-content/70 mb-1">
          Markdown. <code>**bold**</code>, <code>_italic_</code>, <code>[text](url)</code>,
          <code>- bullets</code>, <code>## Heading</code>. Headings are shown one level
          smaller than you write them, because the post title is already the page heading.
        </p>
        <%= f.text_area :body,
              rows: 20,
              class: "textarea w-full font-mono #{"textarea-error" if @news_post.errors[:body].any?}",
              required: true %>
      </div>

      <div>
        <%= f.label :summary, class: "label" do %>
          <span class="font-semibold">Summary</span>
        <% end %>
        <p class="text-sm text-base-content/70 mb-1">
          Optional. Shown on the news index, in search results and on shared links.
          Left empty, the opening of the post is used.
        </p>
        <%= f.text_area :summary, rows: 3, class: "textarea w-full" %>
      </div>
    </div>
  </div>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body space-y-4">
      <fieldset class="fieldset">
        <legend class="fieldset-legend font-semibold">Topics</legend>
        <% if available_topics.any? %>
          <div class="grid grid-cols-2 sm:grid-cols-3 gap-2">
            <% available_topics.each do |topic| %>
              <label class="label cursor-pointer justify-start gap-2">
                <%= check_box_tag "news_post[news_topic_ids][]", topic.id,
                      @news_post.news_topic_ids.include?(topic.id),
                      id: "news_post_news_topic_ids_#{topic.id}",
                      class: "checkbox" %>
                <span><%= topic.name %></span>
              </label>
            <% end %>
          </div>
        <% else %>
          <p class="text-base-content/70">No topics yet. Create one first.</p>
        <% end %>
        <%# Ensures an all-unticked submission clears the topics rather than
            omitting the key entirely. %>
        <%= hidden_field_tag "news_post[news_topic_ids][]", "" %>
      </fieldset>

      <div>
        <%= f.label :published_at, class: "label" do %>
          <span class="font-semibold">Publish date</span>
        <% end %>
        <p class="text-sm text-base-content/70 mb-1">
          Leave empty to keep this a draft. A draft is not reachable at its public URL.
        </p>
        <%= f.datetime_field :published_at, class: "input w-full" %>
      </div>
    </div>
  </div>

  <div class="flex gap-2">
    <%= f.submit(@news_post.persisted? ? "Save Post" : "Create Post", class: "btn btn-primary") %>
    <%= link_to "Cancel", news_posts_path_for, class: "btn btn-ghost" %>
  </div>
<% end %>
```

Create `app/views/admin/news_posts/new.html.erb`:

```erb
<% content_for :title, "New Post" %>
<h1 class="text-2xl font-bold mb-6">New Post</h1>
<%= render "form" %>
```

Create `app/views/admin/news_posts/edit.html.erb`:

```erb
<% content_for :title, "Edit Post" %>
<h1 class="text-2xl font-bold mb-6">Edit Post</h1>
<%= render "form" %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: PASS, 14 runs.

- [ ] **Step 6: Verify the cross-domain topic guard is not vacuous**

Replace `news_post_params`'s intersection with a bare `permitted`, re-run, confirm "create refuses a topic belonging to another domain" goes RED. Restore.

- [ ] **Step 7: Lint, guard, commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/admin test/controllers/admin
git add app/controllers/admin/news_posts_base_controller.rb app/views/admin/news_posts test/controllers/admin/books/news_posts_controller_test.rb
git commit -m "feat(news): add admin news post form"
```

---

### Task 12: Markdown preview

**Files:**
- Modify: `app/controllers/admin/news_posts_base_controller.rb`
- Modify: `app/views/admin/news_posts/_form.html.erb`
- Create: `app/views/admin/news_posts/preview.turbo_stream.erb`
- Create: `app/javascript/controllers/admin/markdown_preview_controller.js`
- Modify: `app/javascript/controllers/index.js`
- Test: `test/controllers/admin/books/news_posts_controller_test.rb` (extend)

**Interfaces:**
- Consumes: `Services::News::BodyRenderer`.
- Produces: `POST /admin/news_posts/preview` returning a turbo-stream replacing `#news_post_preview`. Stimulus controller `admin--markdown-preview` with targets `source`, `form` and value `delay` (ms).

- [ ] **Step 1: Write the failing test**

Append inside `Admin::Books::NewsPostsControllerTest`:

```ruby
test "preview renders Markdown through the public renderer" do
  post preview_admin_books_news_posts_path,
    params: {news_post: {body: "# Heading\n\nSome **bold** text."}},
    as: :turbo_stream

  assert_response :success
  assert_includes response.body, "<h2>Heading</h2>"
  assert_includes response.body, "<strong>bold</strong>"
end

test "preview escapes raw HTML exactly as the public page does" do
  post preview_admin_books_news_posts_path,
    params: {news_post: {body: "<script>alert('x')</script>"}},
    as: :turbo_stream

  assert_not_includes response.body, "<script>alert"
end

test "preview replaces the preview frame" do
  post preview_admin_books_news_posts_path,
    params: {news_post: {body: "hi"}},
    as: :turbo_stream

  assert_includes response.body, 'target="news_post_preview"'
end

test "preview handles an empty body" do
  post preview_admin_books_news_posts_path, params: {news_post: {body: ""}}, as: :turbo_stream

  assert_response :success
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: FAIL — no `preview` action.

- [ ] **Step 3: Add the action**

In `app/controllers/admin/news_posts_base_controller.rb`, add above `private`:

```ruby
# Server-rendered so the preview goes through the exact BodyRenderer the public
# page uses and cannot drift from it. A client-side Markdown library is not an
# option while admin and public share application.js -- it would be downloaded
# by every visitor to every site to serve this one screen.
def preview
  @preview_html = Services::News::BodyRenderer.call(params.dig(:news_post, :body))

  render :preview
end
```

- [ ] **Step 4: Write the turbo-stream template**

Create `app/views/admin/news_posts/preview.turbo_stream.erb`:

```erb
<%= turbo_stream.replace "news_post_preview" do %>
  <div id="news_post_preview" class="prose max-w-none [overflow-wrap:anywhere]">
    <% if @preview_html.blank? %>
      <p class="text-base-content/70">Nothing to preview yet.</p>
    <% else %>
      <%= @preview_html %>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 5: Wire the form**

In `app/views/admin/news_posts/_form.html.erb`, change the body `<div>` to carry the Stimulus controller, and add the preview panel beside it. Replace the whole body field block with:

```erb
<div data-controller="admin--markdown-preview"
     data-admin--markdown-preview-url-value="<%= preview_news_posts_path_for %>"
     data-admin--markdown-preview-delay-value="400">
  <%= f.label :body, class: "label" do %>
    <span class="font-semibold">Body <span class="text-error">*</span></span>
  <% end %>
  <p class="text-sm text-base-content/70 mb-1">
    Markdown. <code>**bold**</code>, <code>_italic_</code>, <code>[text](url)</code>,
    <code>- bullets</code>, <code>## Heading</code>. Headings are shown one level
    smaller than you write them, because the post title is already the page heading.
  </p>

  <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
    <%= f.text_area :body,
          rows: 20,
          class: "textarea w-full font-mono #{"textarea-error" if @news_post.errors[:body].any?}",
          required: true,
          data: {
            admin__markdown_preview_target: "source",
            action: "input->admin--markdown-preview#schedule"
          } %>

    <div class="border border-base-300 rounded-box p-4 overflow-y-auto" style="max-height: 32rem;">
      <div class="text-xs uppercase tracking-wide text-base-content/60 mb-2">Preview</div>
      <%# NOT a turbo_frame_tag: this is a plain div replaced by a turbo-stream,
          so there is no frame for links inside the preview to be trapped by. %>
      <div id="news_post_preview" class="prose max-w-none [overflow-wrap:anywhere]">
        <%= Services::News::BodyRenderer.call(@news_post.body) %>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 6: Write the Stimulus controller**

Create `app/javascript/controllers/admin/markdown_preview_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Debounced server-rendered Markdown preview. Posts the textarea's contents to
// the preview action, which returns a turbo-stream replacing #news_post_preview.
//
// Server-rendered on purpose: the preview then goes through the same
// Services::News::BodyRenderer the public page uses and cannot drift from it.
export default class extends Controller {
  static targets = ["source"]
  static values = { url: String, delay: { type: Number, default: 400 } }

  disconnect() {
    clearTimeout(this.timeout)
    this.abortController?.abort()
  }

  schedule() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.refresh(), this.delayValue)
  }

  async refresh() {
    // Supersede an in-flight request so a slow response cannot overwrite the
    // preview of newer text.
    this.abortController?.abort()
    this.abortController = new AbortController()

    const body = new FormData()
    body.append("news_post[body]", this.sourceTarget.value)

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          Accept: "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body,
        signal: this.abortController.signal
      })

      if (!response.ok) return

      const html = await response.text()
      window.Turbo.renderStreamMessage(html)
    } catch (error) {
      if (error.name !== "AbortError") throw error
    }
  }
}
```

- [ ] **Step 7: Register the controller**

```bash
cd web-app
bin/rails stimulus:manifest:update
```
Verify `app/javascript/controllers/index.js` gained `Admin__MarkdownPreviewController` registered as `admin--markdown-preview`.

- [ ] **Step 8: Run the tests and build**

```bash
bin/rails test test/controllers/admin/books/news_posts_controller_test.rb
yarn build
```
Expected: PASS, 18 runs; build succeeds.

- [ ] **Step 9: Verify the preview cannot drift**

Change `preview` to call `Commonmarker.to_html` directly instead of `BodyRenderer`, re-run, confirm "preview escapes raw HTML" and the heading-shift assertion in "preview renders Markdown through the public renderer" both go RED. Restore.

- [ ] **Step 10: Lint, guard, commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/admin test/controllers/admin
git add app/controllers/admin/news_posts_base_controller.rb app/views/admin/news_posts app/javascript/controllers test/controllers/admin/books/news_posts_controller_test.rb
git commit -m "feat(news): add server-rendered Markdown preview"
```

---

### Task 13: Share image and body images

**Files:**
- Modify: `app/views/admin/news_posts/_form.html.erb`
- Create: `app/views/admin/news_posts/_body_images.html.erb`
- Test: `test/controllers/admin/books/news_posts_controller_test.rb` (extend)
- Test fixture: `test/fixtures/files/` (reuse an existing image)

**Interfaces:**
- Consumes: `NewsPost#share_image`, `NewsPost#body_images` from Task 2.
- Produces: upload fields in the form; a list of uploaded body images each showing its Markdown snippet.

- [ ] **Step 1: Find an existing test image**

Run: `ls test/fixtures/files/`
Use whatever image is already there. If none exists, create a 1×1 PNG:
```bash
printf '\211PNG\r\n\032\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\10\6\0\0\0\37\25\304\211\0\0\0\nIDATx\234c\370\17\0\1\1\1\0\30\335\215\260\0\0\0\0IEND\256B`\202' > test/fixtures/files/pixel.png
```

- [ ] **Step 2: Write the failing tests**

Append inside `Admin::Books::NewsPostsControllerTest`:

```ruby
test "create attaches a share image" do
  post admin_books_news_posts_path, params: {
    news_post: {
      title: "With Image", body: "x",
      share_image: fixture_file_upload("pixel.png", "image/png")
    }
  }

  assert_predicate NewsPost.books.find_by(slug: "with-image").share_image, :attached?
end

test "create attaches body images" do
  post admin_books_news_posts_path, params: {
    news_post: {
      title: "With Body Images", body: "x",
      body_images: [fixture_file_upload("pixel.png", "image/png")]
    }
  }

  assert_equal 1, NewsPost.books.find_by(slug: "with-body-images").body_images.count
end

test "update adds a body image without replacing the existing ones" do
  post_record = news_posts(:books_december_update)
  post_record.body_images.attach(io: File.open(file_fixture("pixel.png")), filename: "a.png")

  patch admin_books_news_post_path(post_record), params: {
    news_post: {
      title: post_record.title, body: post_record.body,
      body_images: [fixture_file_upload("pixel.png", "image/png")]
    }
  }

  assert_equal 2, post_record.reload.body_images.count
end

test "the edit form shows the Markdown snippet for each body image" do
  post_record = news_posts(:books_december_update)
  post_record.body_images.attach(io: File.open(file_fixture("pixel.png")), filename: "cover.png")

  get edit_admin_books_news_post_path(post_record)

  assert_response :success
  assert_includes response.body, "![cover.png]("
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: the four new tests FAIL — no upload fields, no snippet partial.

Note: `has_many_attached` replaces the whole collection on assignment by default in Rails 8. If "update adds a body image without replacing" fails with a count of 1, that is the cause — set `config.active_storage.replace_on_assign_to_many = false` is **deprecated and removed**; instead assign with `post_record.body_images.attach(...)` in the controller rather than through mass assignment. Take that route: remove `body_images: []` from the permitted params and attach explicitly.

- [ ] **Step 4: Attach body images explicitly**

In `app/controllers/admin/news_posts_base_controller.rb`, remove `body_images: []` from `news_post_params`'s permit list, and add to both `create` and `update`, immediately before the `save`/`update` call:

```ruby
attach_body_images
```

and in the private section:

```ruby
# Attached rather than mass-assigned: assigning to a has_many_attached replaces
# the whole collection, so editing a post to add one screenshot would silently
# drop every image already on it.
def attach_body_images
  uploads = params.dig(:news_post, :body_images)
  return if uploads.blank?

  @news_post.body_images.attach(uploads.compact_blank)
end
```

- [ ] **Step 5: Add the form fields**

In `app/views/admin/news_posts/_form.html.erb`, inside the second card's `card-body`, before the publish date field:

```erb
<div>
  <%= f.label :share_image, class: "label" do %>
    <span class="font-semibold">Share image</span>
  <% end %>
  <p class="text-sm text-base-content/70 mb-1">
    Shown when someone posts a link to this article on social media. Wide images work
    best — around 1200 by 630 pixels.
  </p>
  <% if @news_post.share_image.attached? %>
    <div class="mb-2">
      <%= image_tag @news_post.share_image.variant(:card), class: "max-w-xs rounded-box" %>
    </div>
  <% end %>
  <%= f.file_field :share_image, accept: "image/png,image/jpeg,image/webp", class: "file-input w-full" %>
</div>

<div>
  <%= label_tag "news_post_body_images", class: "label" do %>
    <span class="font-semibold">Images for the body</span>
  <% end %>
  <p class="text-sm text-base-content/70 mb-1">
    Upload a screenshot here, then copy the snippet it gives you into the body text
    where you want the picture to appear.
  </p>
  <%= file_field_tag "news_post[body_images][]", multiple: true,
        accept: "image/png,image/jpeg,image/webp,image/gif",
        id: "news_post_body_images", class: "file-input w-full" %>
  <%= render "body_images", news_post: @news_post %>
</div>
```

- [ ] **Step 6: Write the snippet partial**

Create `app/views/admin/news_posts/_body_images.html.erb`:

```erb
<% if news_post.persisted? && news_post.body_images.attached? %>
  <div class="mt-4 space-y-2">
    <% news_post.body_images.each do |image| %>
      <div class="flex items-center gap-3 p-2 border border-base-300 rounded-box">
        <%= image_tag url_for(image), class: "w-16 h-16 object-cover rounded" %>
        <div class="flex-1 min-w-0">
          <div class="text-sm font-semibold truncate"><%= image.filename %></div>
          <code class="text-xs block [overflow-wrap:anywhere]"
                data-controller="clipboard-copy"
                data-clipboard-copy-value="![<%= image.filename %>](<%= url_for(image) %>)">![<%= image.filename %>](<%= url_for(image) %>)</code>
        </div>
      </div>
    <% end %>
  </div>
<% end %>
```

Check `app/javascript/controllers/clipboard_copy_controller.js` for its actual value/target names and match them; if they differ, adjust the data attributes rather than the controller.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/news_posts_controller_test.rb`
Expected: PASS, 22 runs.

- [ ] **Step 8: Verify the attach-not-replace test is not vacuous**

Change `attach_body_images` to `@news_post.body_images = uploads`, re-run, confirm "update adds a body image without replacing the existing ones" goes RED. Restore.

- [ ] **Step 9: Full suite, lint, guard, commit**

```bash
bin/rails test
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/admin test/controllers/admin
git add app/controllers/admin app/views/admin/news_posts test/controllers/admin test/fixtures/files
git commit -m "feat(news): add share image and body image uploads"
```

---

# Increment 4 — Books public

### Task 14: Public news index

**Files:**
- Create: `app/controllers/news_posts_controller.rb`
- Create: `app/views/news_posts/index.html.erb`
- Create: `app/views/news_posts/_card.html.erb`
- Modify: `config/routes.rb`
- Test: `test/controllers/news_posts_controller_test.rb`

**Interfaces:**
- Consumes: `NewsPost`, `NewsTopic`, `Services::News::BodyRenderer`.
- Produces: `NewsPostsController#index`; route helpers `news_path`, `news_page_path(page:)`.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, in the global (non-domain-constrained) section immediately after the `members` route:

```ruby
# News -- global (non-domain-constrained) like /membership and /my/lists: each
# site serves its own posts from one set of routes, with the layout resolved
# from Current.domain in the controller. Edge-cached; drafts 404 rather than
# rendering behind a cache.
#
# The topic route is declared BEFORE the slug route, and "topic" is a
# friendly_id reserved word, so no post can ever claim /news/topic.
get "news", to: "news_posts#index", as: :news
get "news/page/:page", to: "news_posts#index", as: :news_page, constraints: {page: /\d+/}
get "news/topic/:topic_slug", to: "news_posts#index", as: :news_topic
get "news/topic/:topic_slug/page/:page", to: "news_posts#index", as: :news_topic_page,
  constraints: {page: /\d+/}
get "news/:slug", to: "news_posts#show", as: :news_post
```

- [ ] **Step 2: Reserve the topic word**

In `config/initializers/friendly_id.rb`, extend `config.reserved_words`:

```ruby
config.reserved_words = %w[new edit index session login logout users admin
  stylesheets assets javascripts images topic page]
```

- [ ] **Step 3: Write the failing test**

Create `test/controllers/news_posts_controller_test.rb`:

```ruby
require "test_helper"

class NewsPostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "index lists only this domain's published posts" do
    get news_path

    assert_response :success
    assert_equal [news_posts(:books_december_update).id],
      @controller.view_assigns["news_posts"].map(&:id)
  end

  test "index excludes drafts" do
    get news_path

    assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
      news_posts(:books_draft).id
  end

  test "index excludes future-dated posts" do
    get news_path

    assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
      news_posts(:books_scheduled).id
  end

  test "index excludes another domain's posts" do
    get news_path

    assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
      news_posts(:music_launch).id
  end

  test "index orders newest first" do
    older = news_posts(:books_december_update)
    newer = NewsPost.create!(domain: :books, title: "Newer", body: "hi",
      user: users(:admin_user), published_at: 1.hour.ago)

    get news_path

    assert_equal [newer.id, older.id], @controller.view_assigns["news_posts"].map(&:id)
  end

  test "index renders the post title and summary" do
    get news_path

    assert_select "h2", text: /December Update/
    assert_includes response.body, "The December update."
  end

  test "index is edge cacheable" do
    get news_path

    assert_match(/max-age=21600/, response.headers["Cache-Control"])
    assert_match(/public/, response.headers["Cache-Control"])
  end

  test "index serves the books layout on the books host" do
    get news_path

    assert_select "html[data-theme=books]"
  end

  test "index pagination links are path based" do
    12.times do |i|
      NewsPost.create!(domain: :books, title: "Filler #{i}", body: "x",
        user: users(:admin_user), published_at: (i + 2).hours.ago)
    end

    get news_path

    assert_select "nav.pagy a[href='/news/page/2']"
  end

  test "a page past the last one 404s rather than serving an empty cacheable page" do
    assert_raises(ActiveRecord::RecordNotFound) do
      get news_page_path(page: 99)
    end
  end

  test "index on the music host lists music posts" do
    host! "dev.thegreatestmusic.org"

    get news_path

    assert_equal [news_posts(:music_launch).id],
      @controller.view_assigns["news_posts"].map(&:id)
  end
end
```

- [ ] **Step 4: Run to verify it fails**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: FAIL — missing controller.

- [ ] **Step 5: Write the controller**

Create `app/controllers/news_posts_controller.rb`:

```ruby
# The public news section for every site. One route set, one controller, one set
# of views -- the domain comes from Current.domain and the layout from
# DomainLayout, exactly like MembershipController and MyListsController.
class NewsPostsController < ApplicationController
  include Cacheable
  include DomainLayout
  include PathBasedPagination

  layout :resolve_layout

  before_action :cache_for_index_page, only: [:index]
  before_action :find_topic, only: [:index]

  PER_PAGE = 10

  def index
    scope = published_scope.includes(:news_topics).recent
    scope = scope.joins(:news_post_topics).where(news_post_topics: {news_topic_id: @topic.id}) if @topic

    @pagy, @news_posts = pagy_path(scope, limit: PER_PAGE)
    @page_title = @topic ? "#{@topic.name} | News" : "News"
  end

  private

  # Drafts and future-dated posts are excluded here, not in a view conditional:
  # these responses are edge-cached for six hours, so a draft rendered even once
  # would be served to everyone until the entry expired.
  def published_scope
    NewsPost.where(domain: Current.domain).published
  end

  def find_topic
    return if params[:topic_slug].blank?

    @topic = NewsTopic.where(domain: Current.domain).friendly.find(params[:topic_slug])
  end
end
```

- [ ] **Step 6: Write the card partial**

Create `app/views/news_posts/_card.html.erb`:

```erb
<article class="card bg-base-100 shadow-sm">
  <div class="card-body">
    <h2 class="card-title text-2xl [overflow-wrap:anywhere]">
      <%= link_to news_post.title, news_post_path(slug: news_post.slug), class: "link link-hover" %>
    </h2>

    <p class="text-sm text-base-content/70">
      <%= news_post.published_at.strftime("%B %-d, %Y") %>
    </p>

    <p class="[overflow-wrap:anywhere]"><%= news_post.excerpt %></p>

    <% if news_post.news_topics.any? %>
      <div class="flex flex-wrap gap-2 mt-2">
        <% news_post.news_topics.each do |topic| %>
          <%= link_to topic.name, news_topic_path(topic_slug: topic.slug),
                class: "badge badge-outline" %>
        <% end %>
      </div>
    <% end %>

    <div class="card-actions justify-end mt-2">
      <%= link_to "Read more", news_post_path(slug: news_post.slug), class: "btn btn-sm btn-primary" %>
    </div>
  </div>
</article>
```

- [ ] **Step 7: Write the index view**

Create `app/views/news_posts/index.html.erb`:

```erb
<%
  content_for :page_title, "#{@page_title} | #{domain_name}"
  content_for :meta_description,
    @topic ? "News and updates about #{@topic.name.downcase} from #{domain_name}." :
             "Site news, ranking updates and new features from #{domain_name}."
%>

<div class="space-y-8">
  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance">
    <%= @topic ? @topic.name : "News" %>
  </h1>

  <% if @topic %>
    <p class="text-center">
      <%= link_to "All news", news_path, class: "link" %>
    </p>
  <% end %>

  <% if @news_posts.any? %>
    <div class="max-w-3xl mx-auto space-y-6">
      <% @news_posts.each do |news_post| %>
        <%= render "card", news_post: news_post %>
      <% end %>
    </div>

    <div class="flex justify-center">
      <%== @pagy.series_nav %>
    </div>
  <% else %>
    <p class="text-center text-base-content/70">No news yet.</p>
  <% end %>
</div>
```

- [ ] **Step 8: Check how a neighbouring index renders its pagination**

Run: `grep -n "series_nav" app/views/books/lists/index.html.erb app/views/books/**/*.erb`
Match whatever that does exactly — if it passes `anchor_string:` for a Turbo frame, this page does not need it (there is no frame here), but the CSS class names must match so `paging.css` styles it.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: PASS, 11 runs.

- [ ] **Step 10: Verify the draft exclusion is not vacuous**

Change `published_scope` to drop `.published`, re-run, confirm "index excludes drafts" and "index excludes future-dated posts" both go RED. Restore.

- [ ] **Step 11: Lint, guard, commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/news_posts_controller.rb config/routes.rb test/controllers/news_posts_controller_test.rb
git add app/controllers/news_posts_controller.rb app/views/news_posts config/routes.rb config/initializers/friendly_id.rb test/controllers/news_posts_controller_test.rb
git commit -m "feat(news): add public news index"
```

---

### Task 15: Public post page and Open Graph tags

**Files:**
- Modify: `app/controllers/news_posts_controller.rb`
- Create: `app/views/news_posts/show.html.erb`
- Modify: `app/views/layouts/books/application.html.erb`
- Test: `test/controllers/news_posts_controller_test.rb` (extend)

**Interfaces:**
- Consumes: Task 14's controller.
- Produces: `#show`; layout `content_for` keys `:og_title`, `:og_description`, `:og_image`, `:og_type`.

- [ ] **Step 1: Write the failing tests**

Append inside `NewsPostsControllerTest`:

```ruby
test "show renders a published post" do
  get news_post_path(slug: "december-update")

  assert_response :success
  assert_select "h1", text: /December Update/
end

test "show renders the body as HTML from Markdown" do
  get news_post_path(slug: "december-update")

  assert_includes response.body, "<strong>Rankings</strong>"
end

test "show 404s for a draft" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get news_post_path(slug: "something-unfinished")
  end
end

test "show 404s for a future-dated post" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get news_post_path(slug: "next-week")
  end
end

test "show 404s for another domain's post" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get news_post_path(slug: "the-greatest-music-is-live")
  end
end

test "show is edge cacheable for 24 hours" do
  get news_post_path(slug: "december-update")

  assert_match(/max-age=86400/, response.headers["Cache-Control"])
end

test "show sets a canonical url" do
  get news_post_path(slug: "december-update")

  assert_select "link[rel=canonical][href=?]",
    "http://dev-new.thegreatestbooks.org/news/december-update"
end

test "show emits Open Graph tags" do
  get news_post_path(slug: "december-update")

  assert_select "meta[property='og:title'][content=?]", "December Update"
  assert_select "meta[property='og:type'][content=?]", "article"
  assert_select "meta[property='og:description'][content=?]", "The December update."
  assert_select "meta[name='twitter:card']"
end

test "the index page still emits default Open Graph tags" do
  get news_path

  assert_select "meta[property='og:type'][content=?]", "website"
end

test "an existing books page is unaffected by the layout change" do
  get "/lists"

  assert_response :success
  assert_select "meta[property='og:title']"
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: FAIL — no `show` action, no OG tags.

- [ ] **Step 3: Add the show action**

In `app/controllers/news_posts_controller.rb`:

Add to the filters:
```ruby
before_action :cache_for_show_page, only: [:show]
```

Add above `private`:
```ruby
def show
  @news_post = published_scope
    .includes(:news_topics, :user)
    .friendly.find(params[:slug])

  @body_html = Services::News::BodyRenderer.call(@news_post.body)
  @canonical_url = news_post_url(slug: @news_post.slug)
end
```

- [ ] **Step 4: Write the show view**

Create `app/views/news_posts/show.html.erb`:

```erb
<%
  content_for :page_title, "#{@news_post.title} | #{domain_name}"
  content_for :meta_description, @news_post.excerpt(limit: 160)
  content_for :canonical_url, @canonical_url
  content_for :og_title, @news_post.title
  content_for :og_description, @news_post.excerpt(limit: 200)
  content_for :og_type, "article"
  content_for :og_image, url_for(@news_post.share_image.variant(:card)) if @news_post.share_image.attached?
%>

<article class="max-w-3xl mx-auto space-y-6">
  <header class="space-y-3">
    <h1 class="text-3xl sm:text-4xl font-bold text-balance [overflow-wrap:anywhere]">
      <%= @news_post.title %>
    </h1>

    <p class="text-base-content/70">
      <time datetime="<%= @news_post.published_at.iso8601 %>">
        <%= @news_post.published_at.strftime("%B %-d, %Y") %>
      </time>
    </p>

    <% if @news_post.news_topics.any? %>
      <div class="flex flex-wrap gap-2">
        <% @news_post.news_topics.each do |topic| %>
          <%= link_to topic.name, news_topic_path(topic_slug: topic.slug),
                class: "badge badge-outline" %>
        <% end %>
      </div>
    <% end %>
  </header>

  <% if @news_post.share_image.attached? %>
    <%= image_tag @news_post.share_image.variant(:card),
          class: "w-full rounded-box", alt: "" %>
  <% end %>

  <div class="prose max-w-none [overflow-wrap:anywhere]">
    <%= @body_html %>
  </div>

  <footer class="pt-6 border-t border-base-300">
    <%= link_to "← All news", news_path, class: "link" %>
  </footer>
</article>
```

- [ ] **Step 5: Add the Open Graph tags to the books layout**

In `app/views/layouts/books/application.html.erb`, immediately after the existing `<link rel="canonical">` block:

```erb
<%# Open Graph / Twitter card. Every key falls back to the site-level default,
    so pages that set none of them render exactly as they did before. %>
<meta property="og:site_name" content="<%= domain_name %>">
<meta property="og:type" content="<%= content_for?(:og_type) ? yield(:og_type) : "website" %>">
<meta property="og:title" content="<%= content_for?(:og_title) ? yield(:og_title) : strip_tags(yield(:page_title).presence || "The Greatest Books") %>">
<meta property="og:description" content="<%= content_for?(:og_description) ? yield(:og_description) : (content_for?(:meta_description) ? yield(:meta_description) : "Discover definitive rankings of the greatest books of all time.") %>">
<meta property="og:url" content="<%= request.original_url %>">
<% if content_for?(:og_image) %>
  <meta property="og:image" content="<%= yield(:og_image) %>">
  <meta name="twitter:card" content="summary_large_image">
<% else %>
  <meta name="twitter:card" content="summary">
<% end %>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: PASS, 21 runs.

- [ ] **Step 7: Verify the draft 404 is not vacuous**

Change `show` to use `NewsPost.where(domain: Current.domain)` instead of `published_scope`, re-run, confirm "show 404s for a draft" and "show 404s for a future-dated post" both go RED. Restore.

- [ ] **Step 8: Run the full suite**

```bash
bin/rails test
```
Expected: 0 failures. The layout change touches every books page — if any books controller test fails, the fallback chain is wrong; fix it rather than narrowing the test.

- [ ] **Step 9: Lint, guard, commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix app/controllers/news_posts_controller.rb test/controllers/news_posts_controller_test.rb
git add app/controllers/news_posts_controller.rb app/views/news_posts app/views/layouts/books/application.html.erb test/controllers/news_posts_controller_test.rb
git commit -m "feat(news): add public post page and Open Graph tags"
```

---

### Task 16: Topic filter pages and legacy redirects

**Files:**
- Modify: `config/routes.rb`
- Test: `test/controllers/news_posts_controller_test.rb` (extend)

**Interfaces:**
- Consumes: Task 14's `find_topic`.
- Produces: `/blog_posts` and `/blog_posts/:slug` 301s, books-domain-scoped.

- [ ] **Step 1: Write the failing tests**

Append inside `NewsPostsControllerTest`:

```ruby
test "a topic page lists only that topic's posts" do
  get news_topic_path(topic_slug: "rankings")

  assert_response :success
  assert_equal [news_posts(:books_december_update).id],
    @controller.view_assigns["news_posts"].map(&:id)
end

test "a topic page excludes posts without that topic" do
  other = NewsPost.create!(domain: :books, title: "Untagged", body: "x",
    user: users(:admin_user), published_at: 1.hour.ago)

  get news_topic_path(topic_slug: "rankings")

  assert_not_includes @controller.view_assigns["news_posts"].map(&:id), other.id
end

test "a topic page still excludes drafts" do
  news_posts(:books_draft).news_topics << news_topics(:books_rankings)

  get news_topic_path(topic_slug: "rankings")

  assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
    news_posts(:books_draft).id
end

test "an unknown topic 404s" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get news_topic_path(topic_slug: "no-such-topic")
  end
end

test "another domain's topic 404s" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get news_topic_path(topic_slug: "site-news")
  end
end

test "a topic page names the topic in its heading" do
  get news_topic_path(topic_slug: "rankings")

  assert_select "h1", text: "Rankings"
end

test "the legacy blog index 301s to news" do
  get "/blog_posts"

  assert_redirected_to "/news"
  assert_response :moved_permanently
end

test "a legacy blog post url 301s to its news url" do
  get "/blog_posts/december-update"

  assert_redirected_to "/news/december-update"
  assert_response :moved_permanently
end

test "the legacy news index path still resolves" do
  # /news is the legacy index path already -- it must NOT redirect.
  get "/news"

  assert_response :success
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: the redirect tests FAIL with routing errors. The topic tests may already pass from Task 14's `find_topic` — that is fine, they are the regression guard.

- [ ] **Step 3: Add the legacy redirects**

In `config/routes.rb`, inside the books domain constraint block alongside the existing legacy 301s (near `get "lists/help", to: redirect(...)`):

```ruby
# Legacy blog URLs. /news is the legacy index path already and carries over
# unchanged, so it is deliberately absent here.
get "blog_posts", to: redirect("/news", status: 301)
get "blog_posts/:slug", to: redirect("/news/%{slug}", status: 301)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: PASS, 30 runs.

- [ ] **Step 5: Verify the topic filter is not vacuous**

Remove the `scope = scope.joins(...)` line in `#index`, re-run, confirm "a topic page excludes posts without that topic" goes RED. Restore.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix config/routes.rb test/controllers/news_posts_controller_test.rb
git add config/routes.rb test/controllers/news_posts_controller_test.rb
git commit -m "feat(news): add topic filter pages and legacy blog 301s"
```

---

### Task 17: Playwright E2E for books

**Files:**
- Create: `e2e/tests/books/news.spec.ts`

**Interfaces:**
- Consumes: the running dev server on the books host.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Confirm what is actually serving port 3000**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/news -H "Host: dev-new.thegreatestbooks.org"
```
A worktree isolates files only — port 3000 may be serving a **different** worktree, which silently invalidates every E2E result. If this is not the news branch, start this one:
```bash
cd web-app && yarn build:all && bin/rails server
```
(Use `yarn build:all` + `bin/rails server`, not `bin/dev` — foreman self-terminates without a TTY.)

- [ ] **Step 2: Read a neighbouring spec for the harness conventions**

Run: `sed -n '1,30p' e2e/tests/books/lists.spec.ts`
Match its import style and base-URL assumptions exactly.

- [ ] **Step 3: Write the spec**

Create `e2e/tests/books/news.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books news', () => {
  test('the index loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/news');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'News', level: 1 })).toBeVisible();
  });

  test('a card links through to the post page', async ({ page }) => {
    await page.goto('/news');

    const firstPost = page.locator('article h2 a').first();
    const title = (await firstPost.textContent())?.trim() ?? '';
    await firstPost.click();

    await expect(page).toHaveURL(/\/news\/[a-z0-9-]+$/);
    await expect(page.getByRole('heading', { name: title, level: 1 })).toBeVisible();
  });

  test('a post page renders formatted body text', async ({ page }) => {
    await page.goto('/news');
    await page.locator('article h2 a').first().click();

    // The body renders through BodyRenderer, so it is real markup rather than
    // the raw Markdown source.
    await expect(page.locator('.prose')).toBeVisible();
    await expect(page.locator('.prose')).not.toContainText('**');
  });

  test('a post page carries Open Graph tags', async ({ page }) => {
    await page.goto('/news');
    await page.locator('article h2 a').first().click();

    await expect(page.locator('meta[property="og:type"]')).toHaveAttribute('content', 'article');
    await expect(page.locator('meta[property="og:title"]')).not.toHaveAttribute('content', '');
  });

  test('a body heading is never an h1', async ({ page }) => {
    await page.goto('/news');
    await page.locator('article h2 a').first().click();

    // The post title is the page's only h1.
    await expect(page.locator('h1')).toHaveCount(1);
  });

  test('the legacy blog post url redirects', async ({ page }) => {
    await page.goto('/blog_posts/december-update');

    await expect(page).toHaveURL(/\/news\/december-update$/);
  });

  test('a draft is not reachable at its public url', async ({ page }) => {
    const response = await page.goto('/news/something-unfinished');

    expect(response?.status()).toBe(404);
  });
});
```

- [ ] **Step 4: Run it**

```bash
cd web-app && yarn test:e2e --grep "Books news"
```
Expected: all pass. The `december-update` slug exists because Task 8 migrated it; if the dev database was reset, re-run `bin/rails data_migration:news_posts`.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/news.spec.ts
git commit -m "test(news): add Playwright coverage for books news"
```

- [ ] **Step 6: Production migration gate**

`/news` must not go live empty. Before this branch merges, the production run is:
```bash
# on the production host, after the deploy that ships the tables
bin/rails data_migration:news_posts
```
Note this in the PR description. Do not run it yourself without asking.

---

# Increment 5 — RSS

### Task 18: RSS feed

**Files:**
- Modify: `app/controllers/news_posts_controller.rb`
- Create: `app/views/news_posts/index.rss.builder`
- Test: `test/controllers/news_posts_controller_test.rb` (extend)

**Interfaces:**
- Consumes: Task 14's `#index`.
- Produces: `GET /news.rss`.

- [ ] **Step 1: Write the failing tests**

Append inside `NewsPostsControllerTest`:

```ruby
test "the feed renders as rss" do
  get news_path(format: :rss)

  assert_response :success
  assert_equal "application/rss+xml; charset=utf-8", response.media_type + "; charset=utf-8"
  assert_includes response.body, "<rss"
end

test "the feed lists published posts with absolute urls" do
  get news_path(format: :rss)

  assert_includes response.body, "December Update"
  assert_includes response.body, "http://dev-new.thegreatestbooks.org/news/december-update"
end

test "the feed excludes drafts" do
  get news_path(format: :rss)

  assert_not_includes response.body, "Something Unfinished"
end

test "the feed excludes another domain's posts" do
  get news_path(format: :rss)

  assert_not_includes response.body, "The Greatest Music Is Live"
end

test "the feed carries rendered html in the description" do
  get news_path(format: :rss)

  assert_includes response.body, "Rankings"
end

test "the feed is edge cacheable" do
  get news_path(format: :rss)

  assert_match(/max-age=21600/, response.headers["Cache-Control"])
end

test "an unsupported format 404s" do
  assert_raises(ActionController::UnknownFormat) do
    get news_path(format: :json)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: FAIL — no RSS template.

- [ ] **Step 3: Constrain the format and respond**

In `config/routes.rb`, constrain the index route:

```ruby
get "news", to: "news_posts#index", as: :news, defaults: {format: :html},
  constraints: {format: /html|rss/}
```

In `app/controllers/news_posts_controller.rb`, add to `#index` after the pagy call:

```ruby
respond_to do |format|
  format.html
  format.rss { @news_posts = published_scope.includes(:news_topics).recent.limit(FEED_LIMIT) }
end
```

and add the constant beside `PER_PAGE`:

```ruby
# The feed is a fixed window, not a paginated one -- readers refetch it whole.
FEED_LIMIT = 25
```

- [ ] **Step 4: Write the feed template**

Create `app/views/news_posts/index.rss.builder`:

```ruby
xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0", "xmlns:atom": "http://www.w3.org/2005/Atom" do
  xml.channel do
    xml.title "#{domain_name} News"
    xml.link news_url
    xml.description "Site news, ranking updates and new features from #{domain_name}."
    xml.language "en"
    xml.tag!("atom:link", href: news_url(format: :rss), rel: "self", type: "application/rss+xml")

    @news_posts.each do |news_post|
      xml.item do
        xml.title news_post.title
        xml.link news_post_url(slug: news_post.slug)
        # guid is the stable identity a reader dedupes on. isPermaLink false
        # because the slug is frozen but the host may differ between environments.
        xml.guid news_post_url(slug: news_post.slug), isPermaLink: "false"
        xml.pubDate news_post.published_at.rfc822
        xml.description do
          xml.cdata! Services::News::BodyRenderer.call(news_post.body)
        end
        news_post.news_topics.each { |topic| xml.category topic.name }
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/news_posts_controller_test.rb`
Expected: PASS, 37 runs.

- [ ] **Step 6: Verify the feed's draft exclusion is not vacuous**

Change the `format.rss` scope to `NewsPost.where(domain: Current.domain)`, re-run, confirm "the feed excludes drafts" goes RED. Restore.

- [ ] **Step 7: Link the feed from the index**

In `app/views/news_posts/index.html.erb`, inside the opening `<%` block:

```erb
content_for :head_links, tag.link(rel: "alternate", type: "application/rss+xml",
  title: "#{domain_name} News", href: news_url(format: :rss))
```

And in `app/views/layouts/books/application.html.erb`, after the Open Graph block:

```erb
<%= yield(:head_links) if content_for?(:head_links) %>
```

Add a visible link at the foot of `index.html.erb`, inside the outer `space-y-8` div:

```erb
<p class="text-center">
  <%= link_to "Subscribe by RSS", news_path(format: :rss), class: "link" %>
</p>
```

- [ ] **Step 8: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb --fix app/controllers/news_posts_controller.rb config/routes.rb test/controllers/news_posts_controller_test.rb
git add app/controllers/news_posts_controller.rb app/views/news_posts config/routes.rb app/views/layouts/books/application.html.erb test/controllers/news_posts_controller_test.rb
git commit -m "feat(news): add RSS feed"
```

---

# Increment 6 — Games and music

### Task 19: Games and music rollout

**Files:**
- Create: `app/controllers/admin/music/news_posts_controller.rb`
- Create: `app/controllers/admin/music/news_topics_controller.rb`
- Create: `app/controllers/admin/games/news_posts_controller.rb`
- Create: `app/controllers/admin/games/news_topics_controller.rb`
- Modify: `config/routes.rb`
- Modify: `app/lib/admin/domain_nav.rb`
- Modify: `app/views/layouts/music/application.html.erb`
- Modify: `app/views/layouts/games/application.html.erb`
- Create: `e2e/tests/music/news.spec.ts`
- Create: `e2e/tests/games/news.spec.ts`
- Test: `test/controllers/admin/music/news_posts_controller_test.rb`
- Test: `test/controllers/admin/games/news_posts_controller_test.rb`

**Interfaces:**
- Consumes: every base controller and view from Increments 3–5.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/admin/music/news_posts_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Music
    class NewsPostsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index lists only music posts" do
        get admin_news_posts_path

        assert_response :success
        assert_equal [news_posts(:music_launch).id],
          @controller.view_assigns["news_posts"].map(&:id)
      end

      test "create makes a music post, not a books one" do
        post admin_news_posts_path, params: {news_post: {title: "Music News", body: "x"}}

        assert_equal "music", NewsPost.find_by(slug: "music-news").domain
      end

      test "show 404s for a books post" do
        assert_raises(ActiveRecord::RecordNotFound) do
          get admin_news_post_path(news_posts(:books_december_update))
        end
      end

      test "topics index lists only music topics" do
        get admin_news_topics_path

        assert_equal [news_topics(:music_site_news).id],
          @controller.view_assigns["news_topics"].map(&:id)
      end
    end
  end
end
```

Create `test/controllers/admin/games/news_posts_controller_test.rb` — the same four tests with `host! "dev.thegreatest.games"`, the `admin_games_*` path helpers, and `assert_empty @controller.view_assigns["news_posts"]` for the index (there is no games fixture post) plus `assert_equal "games", ...` for create.

- [ ] **Step 2: Add a public rollout test**

Append inside `NewsPostsControllerTest`:

```ruby
test "the games host serves its own empty news index" do
  host! "dev.thegreatest.games"

  get news_path

  assert_response :success
  assert_empty @controller.view_assigns["news_posts"]
  assert_select "html[data-theme]"
end

test "the music post page emits Open Graph tags" do
  host! "dev.thegreatestmusic.org"

  get news_post_path(slug: "the-greatest-music-is-live")

  assert_response :success
  assert_select "meta[property='og:type'][content=?]", "article"
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/music test/controllers/admin/games test/controllers/news_posts_controller_test.rb`
Expected: FAIL — routing errors for the admin paths, missing OG tags on the music layout.

- [ ] **Step 4: Add the routes**

In `config/routes.rb`, inside the **music** domain constraint's `namespace :admin, module: "admin/music"` block:

```ruby
resources :news_topics
resources :news_posts do
  collection do
    post :preview
  end
end
```

And the identical two resource blocks inside the **games** domain constraint's `namespace :admin, module: "admin/games", as: "admin_games"` block.

- [ ] **Step 5: Write the four subclasses**

Create `app/controllers/admin/music/news_posts_controller.rb`:

```ruby
class Admin::Music::NewsPostsController < Admin::NewsPostsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :music

  def news_posts_path_for(params = {}) = admin_news_posts_path(params)

  def news_post_path_for(post) = admin_news_post_path(post)

  def new_news_post_path_for = new_admin_news_post_path

  def edit_news_post_path_for(post) = edit_admin_news_post_path(post)

  def preview_news_posts_path_for = preview_admin_news_posts_path
end
```

Create `app/controllers/admin/music/news_topics_controller.rb`:

```ruby
class Admin::Music::NewsTopicsController < Admin::NewsTopicsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :music

  def news_topics_path_for(params = {}) = admin_news_topics_path(params)

  def news_topic_path_for(topic) = admin_news_topic_path(topic)

  def new_news_topic_path_for = new_admin_news_topic_path

  def edit_news_topic_path_for(topic) = edit_admin_news_topic_path(topic)
end
```

Create `app/controllers/admin/games/news_posts_controller.rb` and `app/controllers/admin/games/news_topics_controller.rb` — identical shape, with `def news_domain = :games` and the `admin_games_*` helpers (`admin_games_news_posts_path`, `admin_games_news_post_path`, `new_admin_games_news_post_path`, `edit_admin_games_news_post_path`, `preview_admin_games_news_posts_path`, and the four topic equivalents).

- [ ] **Step 6: Add the sidebar entries**

In `app/lib/admin/domain_nav.rb`, add to `CONFIGS[:music][:items]`:

```ruby
{label: "News", icon: :chat, path: -> { URL_HELPERS.admin_news_posts_path }},
{label: "News Topics", icon: :category, path: -> { URL_HELPERS.admin_news_topics_path }},
```

and to `CONFIGS[:games][:items]`:

```ruby
{label: "News", icon: :chat, path: -> { URL_HELPERS.admin_games_news_posts_path }},
{label: "News Topics", icon: :category, path: -> { URL_HELPERS.admin_games_news_topics_path }},
```

- [ ] **Step 7: Add Open Graph tags to both layouts**

In `app/views/layouts/music/application.html.erb` and `app/views/layouts/games/application.html.erb`, add the same block written in Task 15 Step 5, changing only the two site-level fallback strings — the `og:title` fallback and the `og:description` fallback — to that site's wording. Both layouts also need:

```erb
<%= yield(:head_links) if content_for?(:head_links) %>
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin test/controllers/news_posts_controller_test.rb`
Expected: PASS.

- [ ] **Step 9: Seed a starter set of topics**

```bash
bin/rails runner '
[:music, :games].each do |domain|
  ["Site News", "Feature Launch", "Rankings", "New Lists"].each do |name|
    NewsTopic.find_or_create_by!(domain: domain, name: name)
  end
end
puts NewsTopic.group(:domain).count.inspect
'
```
Expected: music and games each report 4 (music already has "Site News" as a fixture only in test, so development starts empty).

- [ ] **Step 10: Write the two E2E specs**

Create `e2e/tests/music/news.spec.ts` and `e2e/tests/games/news.spec.ts`. Each is the Books spec from Task 17 minus the legacy-redirect and draft tests (neither site has legacy URLs or the books fixtures), keeping: index loads with an `h1` of "News", a card links through to a post page, the post body renders as markup, and the post page carries `og:type` of `article`. Guard the card-click tests so an empty feed is not a failure:

```typescript
test('a card links through to the post page', async ({ page }) => {
  await page.goto('/news');

  const cards = page.locator('article h2 a');
  const count = await cards.count();
  test.skip(count === 0, 'no published posts on this site yet');

  await cards.first().click();
  await expect(page).toHaveURL(/\/news\/[a-z0-9-]+$/);
});
```

- [ ] **Step 11: Run everything**

```bash
bin/rails test
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb
yarn build:all
yarn test:e2e --grep "news"
```
Expected: 0 failures everywhere. Full-suite total should be roughly 7003 + ~120 new runs.

- [ ] **Step 12: Commit**

```bash
git diff db/schema.rb   # must be empty at this point
git add app/controllers/admin app/lib/admin/domain_nav.rb config/routes.rb app/views/layouts test/controllers/admin e2e/tests
git commit -m "feat(news): roll news out to games and music"
```

- [ ] **Step 13: Finish the branch**

Use the superpowers:finishing-a-development-branch skill. Do **not** push or open a PR without asking. The PR description must record:
- the development migration result (31 created, 31/31 round-trip),
- that `bin/rails data_migration:news_posts` still has to run **in production** with the deploy, because `/news` must not go live empty,
- that `commonmarker` is a new runtime dependency and `reverse_markdown` is removable once the production run is done.

---

## Self-Review

**Spec coverage.** Every section of `2026-08-19-news-posts-design.md` maps to a task:

| Spec section | Task |
|---|---|
| `news_posts` / `news_topics` / `news_post_topics` tables | 1, 2, 3 |
| Markdown storage, two-layer rendering, heading shift | 4 |
| `summary` fallback via block-aware plain text | 2 (`#excerpt`), 4 (`PlainText`) |
| Share image + body images, `Image` not reused | 2 (attachments), 13 (admin) |
| Legacy read models | 5 |
| HTML → Markdown + round-trip check | 6 |
| Migrator, dropped columns, rake tasks | 7 |
| Dev run + hand-review gate | 8 |
| Admin topics CRUD, sidebar entry | 9 |
| Admin post index/show | 10 |
| Admin post form | 11 |
| Server-rendered preview | 12 |
| Global `/news` routes, pagination, caching | 14 |
| Post page, Open Graph, canonical | 15 |
| Topic filter pages, legacy 301s | 16 |
| Playwright | 17, 19 |
| RSS | 18 |
| Games + music rollout | 19 |

Out-of-scope items in the spec (social auto-posting, the JS bundle work, a homepage strip, pinned posts, an integrated rich editor) have deliberately no task.

**Type consistency.** `news_domain`, `news_posts_path_for`, `news_post_path_for`, `new_news_post_path_for`, `edit_news_post_path_for`, `preview_news_posts_path_for` and the four topic equivalents are defined in Tasks 9–10 and used unchanged in Tasks 11, 12 and 19. `Services::News::BodyRenderer.call` and `Services::News::PlainText.call` are defined in Task 4 and used in Tasks 2, 6, 10, 12, 15 and 18 with the same signature. `NewsBodyConverter.call` / `.round_trips?` are defined in Task 6 and used in Task 7.

**Placeholder scan.** Clean. Every code step carries the actual code. The one deferral in the plan is explicit and bounded: Task 2 Step 7 leaves three `excerpt` tests red because `Services::News::BodyRenderer` does not exist until Task 4, and Task 4 Step 9 is where they go green. That is a stated dependency between adjacent tasks, not a missing detail.

**One thing the executor must not "tidy".** `Services::News::PlainText` looks like it could be replaced by `Nokogiri::HTML5.fragment(html).text`. It cannot — that is the block-boundary bug this codebase has already been bitten by, and it silently breaks both `NewsPost#excerpt` and the migration's round-trip verification. The class carries a comment saying so; leave it.
