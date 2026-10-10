# Book Recommendations Collaborative Filtering (Increment 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the readers-like-you signal end to end — Rails exports positive pairs to a store, a Python EASE trainer turns them into item neighbours, Rails loads the neighbours and serves them through `Signals::Collaborative` — and measure it with an honest hold-out in the existing harness.

**Architecture:** Three legs meet at a `Recommendations::Store` (a directory in development, R2 in production): the export leg (`PositivePairs` → `Export` → `ExportInteractionsJob`), the Python leg (`data-sources/src/recommender/`: pairs → EASE → top-k → manifest with a publish gate), and the load/serve leg (`LoadModel` → `recommendation_models` + `recommendation_item_neighbors` → `Signals::Collaborative`, which scores a user's shelf live and passes the ids through the ranked-pool query so every setting applies). The harness gains a deterministic hold-out plan the export can omit, so the model never sees the books the evaluation tests on. Increment 2 (home-server timer, compose, provision, secrets) is a separate plan.

**Tech Stack:** Rails 8, Minitest + Mocha + fixtures, Sidekiq + sidekiq-cron, `aws-sdk-s3` (already in the Gemfile, `require: false`), OpenSearch via `Search::Shared::Client.instance`; Python 3.12, `uv`, numpy, scipy, boto3, typer, pytest, ruff.

**Spec:** `docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md` (spec 2). Spec 1 is `docs/superpowers/specs/2026-10-07-book-recommendations-design.md` (§5.3 signal contract, §5.4 fusion, §8.3 reasons, §9 harness).

## Global Constraints

- Run Rails commands from `web-app/`, Python commands from `data-sources/`. Docs live in `docs/` at the repo root.
- Positive = favorites, read, reading list items, or a rating `>= collaborative_min_rating` (3). Want-to-read and ratings 1–2 are never positives. One definition in SQL (`PositivePairs`) and one in Ruby (`Interaction#trainable?(min_rating:)`); the tests assert they agree.
- Store keys, exactly: `recommendations/<domain>/interactions/<name>.csv.gz`, `recommendations/<domain>/interactions/latest`, `recommendations/<domain>/model/<version>.csv.gz`, `recommendations/<domain>/model/<version>.json`, `recommendations/<domain>/model/latest`. A pointer file holds one line, the name or version. The model version is the export name it was trained on.
- Export CSV: header `user_id,item_id`, sorted by user then item, gzipped. Model CSV: header `item_id,neighbor_id,weight`, sorted by item then weight descending, gzipped.
- Rails store env vars: `RECOMMENDATIONS_R2_ACCOUNT_ID`, `RECOMMENDATIONS_R2_ACCESS_KEY`, `RECOMMENDATIONS_R2_SECRET_KEY`, `RECOMMENDATIONS_R2_BUCKET` (all four or `Store.default` raises). Python: `RECOMMENDER_R2_ACCOUNT_ID`, `RECOMMENDER_R2_ACCESS_KEY`, `RECOMMENDER_R2_SECRET_KEY`, `RECOMMENDER_R2_BUCKET`.
- Shared models stay in the global namespace (AGENTS.md): the spec's `Recommendations::Model` is `RecommendationModel`, its neighbours `RecommendationItemNeighbor`. Generators only: `bin/rails generate model`, `bin/rails generate sidekiq:job`.
- New knobs in `config/initializers/recommendations.rb`: `collaborative: true`, `collaborative_min_rating: 3`, `collaborative_overfetch: 2`, `because_of_rating: 4`. `Config.resolve` raises on unknown keys, so every knob a test overrides must exist there.
- Python defaults: `--lambda 500`, `--min-readers 5`, `--top-k 50`, `--gate-ratio 0.9`, `--eval-seed 1`, `--max-export-age-days 3`. Users with fewer than 2 positives after the item floor are dropped from the matrix.
- Python package `recommender` is a sibling of `openlibrary` and `fetcher`, installed only through the `recommender` extra; `uv sync --locked --extra fetcher --extra recommender` in CI; `ruff check` and `ruff format --check` clean.
- Minitest 6: `assert_nil`, never `assert_equal nil`. Sidekiq test mode is inline. No `brakeman`, lint with `bundle exec standardrb`.
- The DaisyUI/Turbo rules do not apply: this increment adds no view.
- Never run a destructive command against the development database; the harness and the local loop are read-only except for `recommendations:load`, which writes only the two new tables.

## Review Focus

1. A user whose only positives are want-to-read books: `Signals::Collaborative#call` must return `[]` (not query with an empty `IN`), and `signals_used` must not list it. Test in Task 7.
2. A model CSV whose row count disagrees with its manifest (truncated upload): `LoadModel` must leave the old model active, the new row in `loading`, and return a failure naming both counts. Test in Task 5.
3. The hourly load job finding the same version already active: no inserts, no state change, `loaded: false`. Test in Task 5.
4. Neighbour ids that are no longer in the ranked pool (a book unranked since training): they must vanish after the ids filter, and the signal must still return up to `size` from the over-fetched list. Test in Task 7 (filter) and Task 6 (query).
5. An export name with a hold-out suffix must never move `latest`, and `LoadModel` with an explicit `version:` must load it anyway. Tests in Task 4 and Task 5.

---

## File structure

**Rails (`web-app/`)**

| File | Responsibility |
|---|---|
| `app/lib/recommendations/paths.rb` | the five key shapes, one place |
| `app/lib/recommendations/store.rb` | `Store::Local`, `Store::R2`, `Store.default` — `put/get/exist?/read_pointer/write_pointer` |
| `app/lib/recommendations/interaction.rb` | + `trainable?(min_rating:)` |
| `app/lib/recommendations/books/positive_pairs.rb` | the positives SQL, streamed in batches through a cursor |
| `app/lib/recommendations/registry.rb` | + `pairs_class_for(domain)` |
| `app/lib/recommendations/export.rb` | pairs → gzipped CSV → store, optional hold-out, pointer |
| `app/sidekiq/recommendations/export_interactions_job.rb` | nightly, `Store.default` |
| `app/lib/recommendations/evaluation.rb` | + `hold_out_plan` (users, segments, held ids), used by eval and export |
| `app/models/recommendation_model.rb`, `app/models/recommendation_item_neighbor.rb` | the two tables |
| `app/lib/recommendations/load_model.rb` | manifest → rows → atomic version swap → retired cleanup |
| `app/sidekiq/recommendations/load_model_job.rb` | hourly, idempotent |
| `app/lib/recommendations/neighbor_scores.rb` | the one GROUP BY over the neighbour table |
| `app/lib/recommendations/books/adapter.rb` | + `domain`, `filter_candidate_ids` |
| `app/lib/search/books/search/book_recommendations.rb` | `ranked_only` gains `ids:` |
| `app/lib/recommendations/signals/collaborative.rb` | the real signal |
| `lib/tasks/recommendations.rake` | `export`, `load`, eval uses the plan and prints coverage |
| `config/initializers/recommendations.rb`, `config/schedule.yml` | knobs, cron entries |

**Python (`data-sources/`)**

| File | Responsibility |
|---|---|
| `src/recommender/__init__.py` | version |
| `src/recommender/pairs.py` | CSV → index maps → sparse `X`, with the item and user floors |
| `src/recommender/ease.py` | `fit`, `top_neighbors`, `to_sparse` — pure numpy/scipy |
| `src/recommender/evaluate.py` | one-held-out split, batched scoring, hit@10 / recall@50 |
| `src/recommender/manifest.py` | build, gate |
| `src/recommender/store.py` | `Local`, `R2`, `keys` |
| `src/recommender/cli.py` | `train` (files in, files out), `run` (store in, store out, gate, pointer) |
| `recommender.Dockerfile`, `docker-compose.yml` (service `recommender`, profile), `pyproject.toml`, `README.md` | packaging |
| `tests/recommender/test_{pairs,ease,evaluate,manifest,store,cli}.py` | |

---

### Task 1: Store and paths (Rails)

**Files:**
- Create: `web-app/app/lib/recommendations/paths.rb`
- Create: `web-app/app/lib/recommendations/store.rb`
- Test: `web-app/test/lib/recommendations/paths_test.rb`, `web-app/test/lib/recommendations/store_test.rb`

**Interfaces:**
- Produces: `Recommendations::Paths.interactions(domain, name)`, `.interactions_latest(domain)`, `.model(domain, version)`, `.model_manifest(domain, version)`, `.model_latest(domain)` → String keys. `Recommendations::Store::Local.new(dir)`, `Recommendations::Store::R2.new(client:, bucket:)`, `Recommendations::Store::R2.from_env` (nil when unset), `Recommendations::Store.default` (raises `Recommendations::Store::NotConfigured` when the four env vars are absent). Every store answers `put(key, data)` (String, binary), `get(key)` → String or raises `Recommendations::Store::Missing`, `exist?(key)`, `read_pointer(key)` → stripped String or nil, `write_pointer(key, value)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# web-app/test/lib/recommendations/paths_test.rb
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class PathsTest < ActiveSupport::TestCase
    test "keys follow the spec's five shapes" do
      assert_equal "recommendations/books/interactions/2026-10-09.csv.gz", Paths.interactions(:books, "2026-10-09")
      assert_equal "recommendations/books/interactions/latest", Paths.interactions_latest("books")
      assert_equal "recommendations/books/model/2026-10-09.csv.gz", Paths.model(:books, "2026-10-09")
      assert_equal "recommendations/books/model/2026-10-09.json", Paths.model_manifest(:books, "2026-10-09")
      assert_equal "recommendations/books/model/latest", Paths.model_latest(:books)
    end

    test "names with a path separator are refused" do
      assert_raises(ArgumentError) { Paths.interactions(:books, "../x") }
      assert_raises(ArgumentError) { Paths.model(:books, "a/b") }
    end
  end
end
```

```ruby
# web-app/test/lib/recommendations/store_test.rb
# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"

module Recommendations
  class StoreTest < ActiveSupport::TestCase
    def with_env(values)
      old = values.keys.to_h { |k| [k, ENV[k]] }
      values.each { |k, v| ENV[k] = v }
      yield
    ensure
      old.each { |k, v| ENV[k] = v }
    end

    test "local store round-trips binary data, pointers and existence" do
      Dir.mktmpdir do |dir|
        store = Store::Local.new(dir)
        assert_not store.exist?("recommendations/books/model/x.csv.gz")
        assert_nil store.read_pointer("recommendations/books/model/latest")

        store.put("recommendations/books/model/x.csv.gz", "\x1f\x8b\x00binary".b)
        assert store.exist?("recommendations/books/model/x.csv.gz")
        assert_equal "\x1f\x8b\x00binary".b, store.get("recommendations/books/model/x.csv.gz")

        store.write_pointer("recommendations/books/model/latest", "x")
        assert_equal "x", store.read_pointer("recommendations/books/model/latest")
        assert_equal "x\n", File.read(File.join(dir, "recommendations/books/model/latest"))
      end
    end

    test "local store raises Missing for an absent key" do
      Dir.mktmpdir do |dir|
        assert_raises(Store::Missing) { Store::Local.new(dir).get("nope") }
      end
    end

    test "r2 store uses the bucket and keys verbatim" do
      client = Aws::S3::Client.new(stub_responses: true, region: "auto")
      store = Store::R2.new(client: client, bucket: "tg-recs")

      client.stub_responses(:get_object, {body: "payload"})
      assert_equal "payload", store.get("recommendations/books/model/latest")
      assert_equal "tg-recs", client.api_requests.last[:params][:bucket]
      assert_equal "recommendations/books/model/latest", client.api_requests.last[:params][:key]

      store.put("k", "v")
      assert_equal "v", client.api_requests.last[:params][:body]

      client.stub_responses(:head_object, "NotFound")
      assert_not store.exist?("k")
      client.stub_responses(:get_object, "NoSuchKey")
      assert_raises(Store::Missing) { store.get("k") }
      assert_nil store.read_pointer("k")
    end

    test "default is R2 when the four variables are set and raises otherwise" do
      with_env("RECOMMENDATIONS_R2_ACCOUNT_ID" => nil, "RECOMMENDATIONS_R2_ACCESS_KEY" => nil,
        "RECOMMENDATIONS_R2_SECRET_KEY" => nil, "RECOMMENDATIONS_R2_BUCKET" => nil) do
        assert_nil Store::R2.from_env
        assert_raises(Store::NotConfigured) { Store.default }
      end
      with_env("RECOMMENDATIONS_R2_ACCOUNT_ID" => "acct", "RECOMMENDATIONS_R2_ACCESS_KEY" => "a",
        "RECOMMENDATIONS_R2_SECRET_KEY" => "s", "RECOMMENDATIONS_R2_BUCKET" => "b") do
        store = Store.default
        assert_kind_of Store::R2, store
        assert_equal "b", store.bucket
      end
      with_env("RECOMMENDATIONS_R2_ACCOUNT_ID" => "acct", "RECOMMENDATIONS_R2_ACCESS_KEY" => nil,
        "RECOMMENDATIONS_R2_SECRET_KEY" => "s", "RECOMMENDATIONS_R2_BUCKET" => "b") do
        assert_raises(Store::NotConfigured) { Store.default }
      end
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd web-app && bin/rails test test/lib/recommendations/paths_test.rb test/lib/recommendations/store_test.rb`
Expected: errors, `uninitialized constant Recommendations::Paths` / `Recommendations::Store`.

- [ ] **Step 3: Implement**

```ruby
# web-app/app/lib/recommendations/paths.rb
# frozen_string_literal: true

module Recommendations
  # The store keys the export, the trainer and the loader agree on (spec 2
  # §2). The Python side has the same five in recommender/store.py; change
  # both or neither.
  module Paths
    module_function

    def interactions(domain, name)
      "recommendations/#{domain}/interactions/#{safe(name)}.csv.gz"
    end

    def interactions_latest(domain)
      "recommendations/#{domain}/interactions/latest"
    end

    def model(domain, version)
      "recommendations/#{domain}/model/#{safe(version)}.csv.gz"
    end

    def model_manifest(domain, version)
      "recommendations/#{domain}/model/#{safe(version)}.json"
    end

    def model_latest(domain)
      "recommendations/#{domain}/model/latest"
    end

    def safe(name)
      name = name.to_s
      raise ArgumentError, "invalid store name #{name.inspect}" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) && !name.include?("..")

      name
    end
  end
end
```

```ruby
# web-app/app/lib/recommendations/store.rb
# frozen_string_literal: true

require "aws-sdk-s3"

module Recommendations
  # Where exports and models live (spec 2 §2): a directory in development and
  # the harness, a private R2 bucket in production. Files are the interface;
  # the store only moves bytes and one-line pointers. Gzip is the caller's.
  module Store
    class Missing < StandardError; end

    class NotConfigured < StandardError; end

    # R2 when configured, never a silent local fallback: a production job
    # writing into the container's filesystem is the failure this prevents.
    def self.default
      R2.from_env or raise NotConfigured, "set #{R2::ENV_KEYS.join(", ")} to use the recommendations store"
    end

    class Local
      attr_reader :dir

      def initialize(dir)
        @dir = Pathname.new(dir)
      end

      def put(key, data)
        path = @dir.join(key)
        path.dirname.mkpath
        File.binwrite(path, data)
      end

      def get(key)
        path = @dir.join(key)
        raise Missing, key unless path.file?

        File.binread(path)
      end

      def exist?(key)
        @dir.join(key).file?
      end

      def read_pointer(key)
        exist?(key) ? get(key).strip.presence : nil
      end

      def write_pointer(key, value)
        put(key, "#{value}\n")
      end
    end

    class R2
      ENV_KEYS = %w[RECOMMENDATIONS_R2_ACCOUNT_ID RECOMMENDATIONS_R2_ACCESS_KEY
        RECOMMENDATIONS_R2_SECRET_KEY RECOMMENDATIONS_R2_BUCKET].freeze

      attr_reader :bucket

      def self.from_env
        values = ENV_KEYS.map { |k| ENV[k].presence }
        return nil if values.all?(&:nil?)
        raise NotConfigured, "#{ENV_KEYS.join(", ")} must all be set or all be unset" if values.any?(&:nil?)

        account, access, secret, bucket = values
        client = Aws::S3::Client.new(
          endpoint: "https://#{account}.r2.cloudflarestorage.com",
          access_key_id: access, secret_access_key: secret,
          region: "auto", force_path_style: true
        )
        new(client: client, bucket: bucket)
      end

      def initialize(client:, bucket:)
        @client = client
        @bucket = bucket
      end

      def put(key, data)
        @client.put_object(bucket: @bucket, key: key, body: data)
      end

      def get(key)
        @client.get_object(bucket: @bucket, key: key).body.read
      rescue Aws::S3::Errors::NoSuchKey
        raise Missing, key
      end

      def exist?(key)
        @client.head_object(bucket: @bucket, key: key)
        true
      rescue Aws::S3::Errors::NotFound
        false
      end

      def read_pointer(key)
        get(key).strip.presence
      rescue Missing
        nil
      end

      def write_pointer(key, value)
        put(key, "#{value}\n")
      end
    end
  end
end
```

Note `from_env` raises on a partial set: the spec says all four or nothing, and a partial set is a misconfiguration, not "unset".

- [ ] **Step 4: Run the tests, then zeitwerk**

Run: `cd web-app && bin/rails test test/lib/recommendations/paths_test.rb test/lib/recommendations/store_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: all pass; zeitwerk "All is good!".

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/recommendations/paths.rb web-app/app/lib/recommendations/store.rb web-app/test/lib/recommendations/paths_test.rb web-app/test/lib/recommendations/store_test.rb
git commit -m "Recommendations store: local directory and R2 behind one interface"
```

---

### Task 2: Positives — `Interaction#trainable?`, `PositivePairs`, knobs

**Files:**
- Modify: `web-app/config/initializers/recommendations.rb` (fusion block)
- Modify: `web-app/app/lib/recommendations/interaction.rb`
- Create: `web-app/app/lib/recommendations/books/positive_pairs.rb`
- Modify: `web-app/app/lib/recommendations/registry.rb`
- Test: `web-app/test/lib/recommendations/interaction_test.rb` (new), `web-app/test/lib/recommendations/books/positive_pairs_test.rb` (new), `web-app/test/lib/recommendations/registry_test.rb`

**Interfaces:**
- Produces: `Interaction#trainable?(min_rating:)` → Boolean. `Recommendations::Books::PositivePairs.new(min_rating:)#each_batch(batch_size: 50_000) { |rows| }` yielding arrays of `[user_id, item_id]` Integer pairs, sorted by user then item across batches, deduplicated. `Registry.pairs_class_for(domain)`.
- Knobs: `collaborative: true`, `collaborative_min_rating: 3`, `collaborative_overfetch: 2`, `because_of_rating: 4`.

- [ ] **Step 1: Add the knobs**

In `web-app/config/initializers/recommendations.rb`, replace the fusion block:

```ruby
  # Fusion (spec §5.4) and the collaborative signal (spec 2 §6, §7)
  rrf_k: 60,
  taste_weight: 1.0,
  collaborative: true,            # false = the signal reports itself unavailable (the harness's taste-only variant)
  collaborative_half_point: 10,
  collaborative_min_rating: 3,    # a rating at or above this is a positive, for training and for the shelf scored at serving time
  collaborative_overfetch: 2,     # neighbour rows fetched = overfetch × candidate_size, so the ranked-pool filter can drop some and still fill
  because_of_rating: 4,           # "Because you loved X" only names a favorite or a book rated at least this
  rank_prior_weight: 0.3,
```

- [ ] **Step 2: Write the failing tests**

```ruby
# web-app/test/lib/recommendations/interaction_test.rb
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class InteractionTest < ActiveSupport::TestCase
    def interaction(kind:, rating: nil, weight: 1.0)
      Interaction.new(item_id: 1, weight: weight, kind: kind, rating: rating)
    end

    test "list positives are trainable regardless of rating" do
      assert interaction(kind: :favorite).trainable?(min_rating: 3)
      assert interaction(kind: :read).trainable?(min_rating: 3)
      assert interaction(kind: :reading).trainable?(min_rating: 3)
      assert interaction(kind: :read, rating: 1, weight: -1.1).trainable?(min_rating: 3), "a low rating on a read book is still a shelf presence"
    end

    test "want-to-read is never trainable, even with a positive weight" do
      assert_not interaction(kind: :want_to_read, weight: 0.2).trainable?(min_rating: 3)
      assert interaction(kind: :want_to_read, rating: 4).trainable?(min_rating: 3), "unless it is also rated at the floor"
    end

    test "a bare review is trainable only at or above the floor" do
      assert interaction(kind: :review, rating: 3).trainable?(min_rating: 3)
      assert_not interaction(kind: :review, rating: 2).trainable?(min_rating: 3)
      assert_not interaction(kind: :review).trainable?(min_rating: 3), "a text-only review says nothing about taste"
    end
  end
end
```

```ruby
# web-app/test/lib/recommendations/books/positive_pairs_test.rb
# frozen_string_literal: true

require "test_helper"

module Recommendations
  module Books
    class PositivePairsTest < ActiveSupport::TestCase
      # Fixtures: regular_user favorites = war_and_peace, got; read = clash;
      # reviews = war_and_peace ★5, crime_and_punishment ★3. editor_user and
      # admin_user each rate war_and_peace ★4.
      def setup
        @user = users(:regular_user)
        want = ::Books::UserList.create!(user: @user, list_type: :want_to_read, name: "Want")
        want.user_list_items.create!(listable: books_books(:of_mice_and_men))
        custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Shelf")
        custom.user_list_items.create!(listable: books_books(:combo_steinbeck))
        Review.create!(user: @user, reviewable: books_books(:cannery_row), rating: 2)
      end

      def pairs(min_rating: 3, batch_size: 50_000)
        out = []
        PositivePairs.new(min_rating: min_rating).each_batch(batch_size: batch_size) { |rows| out.concat(rows) }
        out
      end

      test "yields favorites, read and rated-at-floor books once each, never want-to-read, custom or low ratings" do
        mine = pairs.select { |u, _| u == @user.id }.map(&:last)
        expected = %i[war_and_peace got clash crime_and_punishment].map { |b| books_books(b).id }.sort
        assert_equal expected, mine.sort
        assert_equal mine.uniq, mine, "a favorite that is also rated appears once"
      end

      test "the floor is a knob" do
        mine = pairs(min_rating: 4).select { |u, _| u == @user.id }.map(&:last)
        assert_not_includes mine, books_books(:crime_and_punishment).id
        assert_includes mine, books_books(:war_and_peace).id
      end

      test "rows are sorted by user then item across batches and include other users' ratings" do
        all = pairs(batch_size: 2)
        assert_equal all.sort, all
        assert_includes all, [users(:editor_user).id, books_books(:war_and_peace).id]
      end

      test "agrees with Interaction#trainable? on the adapter's view of the same user" do
        adapter = Adapter.new(config: Config.resolve)
        from_ruby = adapter.interactions(@user).select { |i| i.trainable?(min_rating: 3) }.map(&:item_id).sort
        from_sql = pairs.select { |u, _| u == @user.id }.map(&:last).sort
        assert_equal from_ruby, from_sql
      end
    end
  end
end
```

Add to `web-app/test/lib/recommendations/registry_test.rb` (inside the class):

```ruby
    test "pairs class per domain" do
      assert_equal Books::PositivePairs, Registry.pairs_class_for(:books)
      assert_nil Registry.pairs_class_for(:music)
    end
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd web-app && bin/rails test test/lib/recommendations/interaction_test.rb test/lib/recommendations/books/positive_pairs_test.rb test/lib/recommendations/registry_test.rb`
Expected: `NoMethodError: trainable?`, `uninitialized constant ... PositivePairs`, `pairs_class_for`.

- [ ] **Step 4: Implement**

`web-app/app/lib/recommendations/interaction.rb`, inside the Struct block after `negative?`:

```ruby
    TRAINABLE_KINDS = %i[favorite read reading].freeze

    # A positive for the collaborative model (spec 2 §3): a shelf presence or
    # a rating at the floor. Same predicate as Books::PositivePairs's SQL; the
    # pairs test asserts the two agree. Not the signed weight: want-to-read is
    # weighted positive but is not a positive here.
    def trainable?(min_rating:)
      TRAINABLE_KINDS.include?(kind) || (!rating.nil? && rating >= min_rating)
    end
```

```ruby
# web-app/app/lib/recommendations/books/positive_pairs.rb
# frozen_string_literal: true

module Recommendations
  module Books
    # Every (user, book) positive pair for the collaborative export (spec 2
    # §3): favorites, read and reading list items, and reviews rated at the
    # floor. One UNION streamed through a server-side cursor, sorted so the
    # export file is deterministic. Root-anchored constants: inside
    # Recommendations::Books a bare Books::UserList resolves wrongly.
    class PositivePairs
      LIST_TYPES = %w[favorites read reading].freeze

      def initialize(min_rating:)
        @min_rating = min_rating.to_i
      end

      def each_batch(batch_size: 50_000)
        conn = ::ActiveRecord::Base.connection
        conn.transaction do
          conn.execute("DECLARE recommendation_positive_pairs NO SCROLL CURSOR FOR #{sql}")
          loop do
            rows = conn.select_rows("FETCH FORWARD #{batch_size.to_i} FROM recommendation_positive_pairs")
            break if rows.empty?

            yield rows.map { |user_id, item_id| [user_id.to_i, item_id.to_i] }
          end
          conn.execute("CLOSE recommendation_positive_pairs")
        end
      end

      private

      def sql
        list_types = LIST_TYPES.map { |name| ::Books::UserList.list_types.fetch(name) }.join(", ")
        <<~SQL
          SELECT user_id, item_id FROM (
            SELECT ul.user_id AS user_id, uli.listable_id AS item_id
              FROM user_list_items uli
              JOIN user_lists ul ON ul.id = uli.user_list_id
             WHERE ul.type = 'Books::UserList'
               AND uli.listable_type = 'Books::Book'
               AND ul.list_type IN (#{list_types})
            UNION
            SELECT user_id, reviewable_id
              FROM reviews
             WHERE reviewable_type = 'Books::Book'
               AND rating >= #{@min_rating}
          ) pairs
          ORDER BY user_id, item_id
        SQL
      end
    end
  end
end
```

`web-app/app/lib/recommendations/registry.rb`: add `DOMAIN_PAIRS = {"books" => "Recommendations::Books::PositivePairs"}.freeze` beside the other maps and

```ruby
    def self.pairs_class_for(domain)
      DOMAIN_PAIRS[domain.to_s]&.constantize
    end
```

and extend the class comment: "Which adapter, page loader, positive-pairs query and membership feature serve which domain."

- [ ] **Step 5: Run the tests and lint**

Run: `cd web-app && bin/rails test test/lib/recommendations/ && bundle exec standardrb app/lib/recommendations test/lib/recommendations config/initializers/recommendations.rb`
Expected: pass; the existing `Config` and `signals_test` still pass (the new knobs have defaults).

- [ ] **Step 6: Commit**

```bash
git add web-app/config/initializers/recommendations.rb web-app/app/lib/recommendations/interaction.rb web-app/app/lib/recommendations/books/positive_pairs.rb web-app/app/lib/recommendations/registry.rb web-app/test/lib/recommendations/interaction_test.rb web-app/test/lib/recommendations/books/positive_pairs_test.rb web-app/test/lib/recommendations/registry_test.rb
git commit -m "Collaborative positives: one definition in SQL and in Interaction#trainable?"
```

---
### Task 3: `Evaluation.hold_out_plan` — one deterministic sample for eval and export

**Files:**
- Modify: `web-app/app/lib/recommendations/evaluation.rb`
- Modify: `web-app/lib/tasks/recommendations.rake` (the `eval` task's sampling loop)
- Test: `web-app/test/lib/recommendations/evaluation_test.rb`

**Interfaces:**
- Consumes: `Evaluation.candidate_ids`, `sample_user_ids`, `split`, `eligible?`, `MIN_ELIGIBLE`; `Adapter#interactions(user)`.
- Produces: `Evaluation.hold_out_plan(domain:, adapter:, users:, seed:, fraction:)` → `HoldOutPlan` Struct with `segments` (`{"5-19" => [user_id, ...], ...}`, every sampled id) and `held` (`{user_id => [item_id, ...]}` for the users that pass the eligibility check). The export (Task 4) omits `held`; eval iterates `segments` and skips users absent from `held`.

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/lib/recommendations/evaluation_test.rb`:

```ruby
    test "hold_out_plan is deterministic for a seed and holds out only eligible ranked items" do
      config = ranking_configurations(:books_global)
      user = users(:regular_user)
      # Make regular_user eligible: five favorites in the ranked pool.
      favorites = user_lists(:regular_user_books_favorites)
      five = (1..5).map do |n|
        book = ::Books::Book.create!(title: "Ranked #{n}")
        ::RankedItem.create!(item: book, ranking_configuration: config, rank: n, score: 1)
        favorites.user_list_items.create!(listable: book)
        book.id
      end
      adapter = Books::Adapter.new(config: Config.resolve)

      a = Evaluation.hold_out_plan(domain: :books, adapter: adapter, users: 30, seed: 7, fraction: 0.4)
      b = Evaluation.hold_out_plan(domain: :books, adapter: adapter, users: 30, seed: 7, fraction: 0.4)
      assert_equal a, b
      assert_equal Evaluation::SEGMENTS.keys, a.segments.keys
      assert_includes a.segments.values.flatten, user.id
      held = a.held.fetch(user.id)
      assert_equal 2, held.size, "0.4 of five eligible favorites, rounded up"
      assert held.all? { |id| five.include?(id) }, "only ranked favorites are held out; the unranked fixture favorites stay"
    end

    test "hold_out_plan leaves out a sampled user who falls below MIN_ELIGIBLE on exact interactions" do
      adapter = Books::Adapter.new(config: Config.resolve)
      plan = Evaluation.hold_out_plan(domain: :books, adapter: adapter, users: 30, seed: 7, fraction: 0.2)
      plan.segments.values.flatten.each do |user_id|
        next unless plan.held.key?(user_id)

        interactions = adapter.interactions(User.find(user_id))
        assert_operator interactions.count { |i| Evaluation.eligible?(i) }, :>=, Evaluation::MIN_ELIGIBLE
      end
    end
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd web-app && bin/rails test test/lib/recommendations/evaluation_test.rb`
Expected: `NoMethodError: undefined method 'hold_out_plan'`.

- [ ] **Step 3: Implement**

In `web-app/app/lib/recommendations/evaluation.rb`, after `SEGMENTS`:

```ruby
    HoldOutPlan = Struct.new(:segments, :held, keyword_init: true)
```

and after `sample_user_ids`:

```ruby
    # The sample and the hold-out, computed once and shared by `recommendations:eval`
    # and `recommendations:export HOLDOUT_SEED=` (spec 2 §8.2): the export omits
    # exactly the pairs eval will test on, so a model trained on it has never
    # seen them. Deterministic for (seed, users, fraction) against one database.
    # Users whose exact interactions fall below MIN_ELIGIBLE (the SQL count is
    # an approximation) are sampled but absent from `held`.
    def hold_out_plan(domain:, adapter:, users:, seed:, fraction:)
      random = Random.new(seed)
      pool = candidate_ids(domain: domain)
      segments = sample_user_ids(domain: domain, per_segment: users / 3, random: random, candidate_ids: pool)
      held = {}
      segments.each_value do |user_ids|
        user_ids.each do |user_id|
          interactions = adapter.interactions(::User.find(user_id))
          _, out = split(interactions, fraction: fraction, random: Random.new(seed + user_id), candidate_ids: pool)
          next if out.empty? || interactions.count { |i| eligible?(i) && pool.include?(i.item_id) } < MIN_ELIGIBLE

          held[user_id] = out.map(&:item_id)
        end
      end
      HoldOutPlan.new(segments: segments, held: held)
    end
```

In `web-app/lib/tasks/recommendations.rake`, the `eval` task: replace the lines that build `random`, `candidate_ids` and `segments` with

```ruby
    config = Recommendations::Config.resolve
    adapter = Recommendations::Books::Adapter.new(config: config)
    candidate_ids = Recommendations::Evaluation.candidate_ids(domain: :books)
    plan = Recommendations::Evaluation.hold_out_plan(domain: :books, adapter: adapter, users: users_total, seed: seed, fraction: fraction)
    segments = plan.segments
```

(keep the `pool_size` and `eligible_users` lines), and the top of `user_ids.each do |user_id|` becomes

```ruby
        held_ids = plan.held[user_id]
        next if held_ids.nil?

        user = User.find(user_id)
        evaluated += 1
        excluded = adapter.shelved_item_ids(user) - held_ids
        criteria = adapter.criteria_for(user)
```

The old `interactions = adapter.interactions(user)`, `_, held = ...split(...)`, the `next if held.size < 1 || ...` guard and `held_ids = held.map(&:item_id)` go away.

- [ ] **Step 4: Run the tests, then a tiny eval to prove nothing drifted**

Run: `cd web-app && bin/rails test test/lib/recommendations/evaluation_test.rb && bin/rails recommendations:eval USERS=30 SEED=42 2>&1 | head -20`
Expected: tests pass; eval prints the three segments as before (needs the dev database and OpenSearch).

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/recommendations/evaluation.rb web-app/lib/tasks/recommendations.rake web-app/test/lib/recommendations/evaluation_test.rb
git commit -m "Harness: one deterministic hold-out plan shared by eval and the export"
```

---

### Task 4: Export — `Recommendations::Export`, the nightly job, `recommendations:export`

**Files:**
- Create: `web-app/app/lib/recommendations/export.rb`
- Create (generator): `web-app/app/sidekiq/recommendations/export_interactions_job.rb`, `web-app/test/sidekiq/recommendations/export_interactions_job_test.rb`
- Modify: `web-app/config/schedule.yml`, `web-app/lib/tasks/recommendations.rake`
- Test: `web-app/test/lib/recommendations/export_test.rb`

**Interfaces:**
- Consumes: `Registry.pairs_class_for`, `PositivePairs#each_batch`, `Store`, `Paths`, `Evaluation.hold_out_plan`, `Config.resolve`.
- Produces: `Recommendations::Export.call(domain:, store:, name: Date.current.iso8601, hold_out: nil, config: Config.resolve)` → `Result(success?, data: {name:, key:, rows:, omitted:, pointer_moved:}, errors:)`. With `hold_out` (a `{user_id => [item_id]}` map) the pointer is not moved. `Recommendations::ExportInteractionsJob#perform(domain = "books")`.

- [ ] **Step 1: Generate the job**

Run: `cd web-app && bin/rails generate sidekiq:job recommendations/export_interactions`
Expected: `app/sidekiq/recommendations/export_interactions_job.rb` and `test/sidekiq/recommendations/export_interactions_job_test.rb` created.

- [ ] **Step 2: Write the failing tests**

```ruby
# web-app/test/lib/recommendations/export_test.rb
# frozen_string_literal: true

require "test_helper"
require "zlib"
require "csv"

module Recommendations
  class ExportTest < ActiveSupport::TestCase
    def setup
      @user = users(:regular_user)
    end

    def rows_in(store, key)
      CSV.parse(Zlib.gunzip(store.get(key)), headers: true).map { |r| [r["user_id"].to_i, r["item_id"].to_i] }
    end

    test "writes a gzipped, sorted csv with a header and moves the pointer" do
      Dir.mktmpdir do |dir|
        store = Store::Local.new(dir)
        result = Export.call(domain: :books, store: store, name: "2026-10-09")
        assert result.success?, result.errors.inspect
        assert_equal "recommendations/books/interactions/2026-10-09.csv.gz", result.data[:key]
        rows = rows_in(store, result.data[:key])
        assert_equal rows.sort, rows
        assert_includes rows, [@user.id, books_books(:war_and_peace).id]
        assert_equal rows.size, result.data[:rows]
        assert result.data[:pointer_moved]
        assert_equal "2026-10-09", store.read_pointer(Paths.interactions_latest(:books))
        assert_equal "user_id,item_id", Zlib.gunzip(store.get(result.data[:key])).lines.first.strip
      end
    end

    test "a hold-out omits exactly those pairs and leaves the pointer alone" do
      Dir.mktmpdir do |dir|
        store = Store::Local.new(dir)
        store.write_pointer(Paths.interactions_latest(:books), "2026-10-01")
        held = {@user.id => [books_books(:war_and_peace).id]}
        result = Export.call(domain: :books, store: store, name: "2026-10-09-holdout-42", hold_out: held)
        assert result.success?
        rows = rows_in(store, result.data[:key])
        assert_not_includes rows, [@user.id, books_books(:war_and_peace).id]
        assert_includes rows, [@user.id, books_books(:got).id]
        assert_equal 1, result.data[:omitted]
        assert_not result.data[:pointer_moved]
        assert_equal "2026-10-01", store.read_pointer(Paths.interactions_latest(:books))
      end
    end

    test "an unknown domain is a failure, not an exception" do
      Dir.mktmpdir do |dir|
        result = Export.call(domain: :music, store: Store::Local.new(dir))
        assert_not result.success?
        assert_match(/music/, result.errors.first)
      end
    end
  end
end
```

```ruby
# web-app/test/sidekiq/recommendations/export_interactions_job_test.rb
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ExportInteractionsJobTest < ActiveSupport::TestCase
    test "runs on the low queue" do
      assert_equal "low", ExportInteractionsJob.get_sidekiq_options["queue"].to_s
    end

    test "exports the domain through the default store" do
      store = Store::Local.new(Dir.mktmpdir)
      Store.stubs(:default).returns(store)
      ExportInteractionsJob.new.perform("books")
      assert store.exist?(Paths.interactions_latest(:books))
    end

    test "raises when the export fails so Sidekiq retries" do
      Store.stubs(:default).returns(Store::Local.new(Dir.mktmpdir))
      Export.stubs(:call).returns(Export::Result.new(success?: false, data: nil, errors: ["boom"]))
      error = assert_raises(RuntimeError) { ExportInteractionsJob.new.perform("books") }
      assert_includes error.message, "boom"
    end

    test "is scheduled nightly" do
      entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("recommendations_export_books")
      assert_equal "Recommendations::ExportInteractionsJob", entry["class"]
      assert_equal "30 2 * * *", entry["cron"]
      assert_equal ["books"], entry["args"]
    end
  end
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd web-app && bin/rails test test/lib/recommendations/export_test.rb test/sidekiq/recommendations/export_interactions_job_test.rb`
Expected: `uninitialized constant Recommendations::Export`; the schedule test fails on the missing key.

- [ ] **Step 4: Implement**

```ruby
# web-app/app/lib/recommendations/export.rb
# frozen_string_literal: true

require "zlib"

module Recommendations
  # The interaction export (spec 2 §3): every positive pair for a domain as
  # one gzipped CSV in the store, plus the `latest` pointer. With a hold-out
  # the named pairs are omitted and the pointer is left alone -- that file
  # exists for the harness, never for production training.
  module Export
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    def self.call(domain:, store:, name: Date.current.iso8601, hold_out: nil, config: Config.resolve)
      pairs_class = Registry.pairs_class_for(domain)
      return Result.new(success?: false, data: nil, errors: ["no positive pairs for domain #{domain}"]) if pairs_class.nil?

      held = (hold_out || {}).transform_values(&:to_set)
      rows = 0
      omitted = 0
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write("user_id,item_id\n")
      pairs_class.new(min_rating: config[:collaborative_min_rating]).each_batch do |batch|
        batch.each do |user_id, item_id|
          if held[user_id]&.include?(item_id)
            omitted += 1
            next
          end
          gz.write("#{user_id},#{item_id}\n")
          rows += 1
        end
      end
      gz.close

      key = Paths.interactions(domain, name)
      store.put(key, io.string)
      pointer_moved = hold_out.nil?
      store.write_pointer(Paths.interactions_latest(domain), name) if pointer_moved
      Result.new(success?: true, errors: [], data: {name: name, key: key, rows: rows, omitted: omitted, pointer_moved: pointer_moved})
    end
  end
end
```

```ruby
# web-app/app/sidekiq/recommendations/export_interactions_job.rb
# frozen_string_literal: true

# Nightly (config/schedule.yml): write the domain's positive pairs to the
# recommendations store for the home server's trainer (spec 2 §3). Store.default
# raises when R2 is not configured, which is the right outcome in production.
module Recommendations
  class ExportInteractionsJob
    include Sidekiq::Job

    sidekiq_options queue: :low

    def perform(domain = "books")
      result = Export.call(domain: domain, store: Store.default)
      raise "Recommendations::ExportInteractionsJob #{domain}: #{result.errors.join(", ")}" unless result.success?

      Rails.logger.info "[Recommendations::ExportInteractionsJob] #{domain}: #{result.data[:rows]} rows to #{result.data[:key]}"
    end
  end
end
```

Append to `web-app/config/schedule.yml`:

```yaml

recommendations_export_books:
  class: Recommendations::ExportInteractionsJob
  cron: "30 2 * * *"
  args: ["books"]
  description: "Export the books positive pairs for the collaborative-filtering trainer"
```

Append to `web-app/lib/tasks/recommendations.rake`, inside `namespace :recommendations`:

```ruby
  desc "Write the positive-pair export (DIR=dir for a local store, else R2; HOLDOUT_SEED/HOLDOUT_USERS/HOLDOUT_FRACTION omit the harness's hold-out)"
  task export: :environment do
    store = ENV["DIR"].present? ? Recommendations::Store::Local.new(ENV["DIR"]) : Recommendations::Store.default
    name = Date.current.iso8601
    hold_out = nil
    if ENV["HOLDOUT_SEED"].present?
      seed = ENV["HOLDOUT_SEED"].to_i
      adapter = Recommendations::Books::Adapter.new(config: Recommendations::Config.resolve)
      plan = Recommendations::Evaluation.hold_out_plan(domain: :books, adapter: adapter,
        users: ENV.fetch("HOLDOUT_USERS", "500").to_i, seed: seed, fraction: ENV.fetch("HOLDOUT_FRACTION", "0.2").to_f)
      hold_out = plan.held
      name = "#{name}-holdout-#{seed}"
      puts "hold-out: #{hold_out.size} users, #{hold_out.values.sum(&:size)} pairs omitted"
    end
    result = Recommendations::Export.call(domain: :books, store: store, name: name, hold_out: hold_out)
    abort result.errors.join(", ") unless result.success?
    puts "wrote #{result.data[:rows]} rows to #{result.data[:key]}#{" (pointer not moved)" unless result.data[:pointer_moved]}"
  end
```

- [ ] **Step 5: Run the tests, lint, and one real export**

Run: `cd web-app && bin/rails test test/lib/recommendations/export_test.rb test/sidekiq/recommendations/export_interactions_job_test.rb && bundle exec standardrb app/lib/recommendations app/sidekiq/recommendations lib/tasks/recommendations.rake test/lib/recommendations test/sidekiq/recommendations && bin/rails recommendations:export DIR=tmp/recommendations`
Expected: tests pass; the export prints about 3 million rows to `tmp/recommendations/recommendations/books/interactions/<today>.csv.gz` in well under five minutes. `tmp/` is gitignored.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/recommendations/export.rb web-app/app/sidekiq/recommendations/export_interactions_job.rb web-app/test/sidekiq/recommendations/export_interactions_job_test.rb web-app/test/lib/recommendations/export_test.rb web-app/config/schedule.yml web-app/lib/tasks/recommendations.rake
git commit -m "Recommendations export: positive pairs to the store, nightly and from rake"
```

---

### Task 5: The model tables, `LoadModel`, the hourly job, `recommendations:load`

**Files:**
- Create (generators): `web-app/db/migrate/*_create_recommendation_models.rb`, `*_create_recommendation_item_neighbors.rb`, `web-app/app/models/recommendation_model.rb`, `web-app/app/models/recommendation_item_neighbor.rb`, their generated tests and fixtures
- Create: `web-app/app/lib/recommendations/load_model.rb`
- Create (generator): `web-app/app/sidekiq/recommendations/load_model_job.rb` + test
- Modify: `web-app/config/schedule.yml`, `web-app/lib/tasks/recommendations.rake`
- Test: `web-app/test/lib/recommendations/load_model_test.rb`, `web-app/test/models/recommendation_model_test.rb`

**Interfaces:**
- Produces: `RecommendationModel` (`domain`, `version`, `manifest` jsonb, `state` enum `loading/active/retired`, `has_many :recommendation_item_neighbors`, `.active_for(domain)` → record or nil). `RecommendationItemNeighbor` (`recommendation_model_id`, `item_id`, `neighbor_id`, `weight`). `Recommendations::LoadModel.call(domain:, store:, version: nil)` → `Result(success?, data: {loaded:, version:, rows:}, errors:)`. `Recommendations::LoadModelJob#perform(domain = "books")`.

- [ ] **Step 1: Generate**

```bash
cd web-app
bin/rails generate model RecommendationModel domain:string version:string manifest:jsonb state:integer
bin/rails generate model RecommendationItemNeighbor recommendation_model:references item_id:bigint neighbor_id:bigint weight:float --no-timestamps
```

Edit the two migrations to:

```ruby
class CreateRecommendationModels < ActiveRecord::Migration[8.1]
  def change
    create_table :recommendation_models do |t|
      t.string :domain, null: false
      t.string :version, null: false
      t.jsonb :manifest, null: false, default: {}
      t.integer :state, null: false, default: 0
      t.timestamps
    end
    add_index :recommendation_models, [:domain, :version], unique: true
    add_index :recommendation_models, [:domain, :state]
  end
end
```

```ruby
class CreateRecommendationItemNeighbors < ActiveRecord::Migration[8.1]
  def change
    create_table :recommendation_item_neighbors do |t|
      t.references :recommendation_model, null: false, foreign_key: true, index: false
      t.bigint :item_id, null: false
      t.bigint :neighbor_id, null: false
      t.float :weight, null: false
    end
    add_index :recommendation_item_neighbors, [:recommendation_model_id, :item_id]
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: both tables in `db/schema.rb`; annotaterb adds schema comments to the models.

Delete the generated fixture files `test/fixtures/recommendation_models.yml` and `test/fixtures/recommendation_item_neighbors.yml` (the tests build their own rows; an empty fixture file would be a vacuous corpus).

- [ ] **Step 2: Write the models**

```ruby
# web-app/app/models/recommendation_model.rb  (below the annotation block)
# One trained collaborative model per domain and version (spec 2 §5). A load
# inserts under `loading`, then swaps to `active` in one transaction while the
# previous active row is retired, so the signal never reads a half-loaded
# model. The version is the export name the trainer read.
class RecommendationModel < ApplicationRecord
  has_many :recommendation_item_neighbors, dependent: :delete_all

  enum :state, {loading: 0, active: 1, retired: 2}

  validates :domain, :version, presence: true
  validates :version, uniqueness: {scope: :domain}

  def self.active_for(domain)
    active.find_by(domain: domain.to_s)
  end
end
```

```ruby
# web-app/app/models/recommendation_item_neighbor.rb
# "A reader who shelved item_id is led to neighbor_id with this weight": one
# row of the trainer's top-k EASE matrix (spec 2 §4.2). No timestamps and no
# item FK on purpose -- a million rows, replaced wholesale on every load.
class RecommendationItemNeighbor < ApplicationRecord
  belongs_to :recommendation_model
end
```

Replace the generated model tests:

```ruby
# web-app/test/models/recommendation_model_test.rb
# frozen_string_literal: true

require "test_helper"

class RecommendationModelTest < ActiveSupport::TestCase
  test "version is unique per domain and active_for returns the one active model" do
    a = RecommendationModel.create!(domain: "books", version: "2026-10-01", state: :retired)
    b = RecommendationModel.create!(domain: "books", version: "2026-10-02", state: :active)
    assert_not RecommendationModel.new(domain: "books", version: "2026-10-02").valid?
    assert RecommendationModel.new(domain: "music", version: "2026-10-02").valid?
    assert_equal b, RecommendationModel.active_for(:books)
    assert_nil RecommendationModel.active_for(:music)
    assert_not_equal a, RecommendationModel.active_for("books")
  end

  test "deleting a model deletes its neighbours" do
    model = RecommendationModel.create!(domain: "books", version: "v")
    model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 2, weight: 0.5)
    model.destroy!
    assert_equal 0, RecommendationItemNeighbor.count
  end
end
```

```ruby
# web-app/test/models/recommendation_item_neighbor_test.rb
# frozen_string_literal: true

require "test_helper"

class RecommendationItemNeighborTest < ActiveSupport::TestCase
  test "belongs to a model and requires a weight" do
    model = RecommendationModel.create!(domain: "books", version: "v")
    row = model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 2, weight: 0.25)
    assert_equal model, row.recommendation_model
    assert_raises(ActiveRecord::NotNullViolation) { model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 3, weight: nil) }
  end
end
```

- [ ] **Step 3: Generate the job and write the failing loader tests**

Run: `bin/rails generate sidekiq:job recommendations/load_model`

```ruby
# web-app/test/lib/recommendations/load_model_test.rb
# frozen_string_literal: true

require "test_helper"
require "zlib"

module Recommendations
  class LoadModelTest < ActiveSupport::TestCase
    ROWS = [[1, 2, 0.9], [1, 3, 0.4], [2, 1, 0.8]].freeze

    def publish(store, version, rows: ROWS, manifest_rows: rows.size, latest: true)
      csv = "item_id,neighbor_id,weight\n" + rows.map { |r| r.join(",") }.join("\n") + "\n"
      store.put(Paths.model(:books, version), Zlib.gzip(csv))
      store.put(Paths.model_manifest(:books, version), JSON.generate({"domain" => "books", "export" => version, "rows" => manifest_rows, "items" => 2}))
      store.write_pointer(Paths.model_latest(:books), version) if latest
    end

    def setup
      @dir = Dir.mktmpdir
      @store = Store::Local.new(@dir)
    end

    test "loads latest, activates it, and stores the manifest" do
      publish(@store, "2026-10-09")
      result = LoadModel.call(domain: :books, store: @store)
      assert result.success?, result.errors.inspect
      assert result.data[:loaded]
      assert_equal 3, result.data[:rows]
      model = RecommendationModel.active_for(:books)
      assert_equal "2026-10-09", model.version
      assert_equal 3, model.manifest["rows"]
      assert_equal [[1, 2, 0.9], [1, 3, 0.4], [2, 1, 0.8]], model.recommendation_item_neighbors.order(:item_id, weight: :desc).pluck(:item_id, :neighbor_id, :weight)
    end

    test "a second run for the same version does nothing" do
      publish(@store, "2026-10-09")
      LoadModel.call(domain: :books, store: @store)
      result = LoadModel.call(domain: :books, store: @store)
      assert result.success?
      assert_not result.data[:loaded]
      assert_equal 1, RecommendationModel.count
      assert_equal 3, RecommendationItemNeighbor.count
    end

    test "a newer version retires the old one and removes its rows" do
      publish(@store, "2026-10-08")
      LoadModel.call(domain: :books, store: @store)
      publish(@store, "2026-10-09", rows: [[5, 6, 0.1]])
      result = LoadModel.call(domain: :books, store: @store)
      assert result.data[:loaded]
      assert_equal "2026-10-09", RecommendationModel.active_for(:books).version
      assert_nil RecommendationModel.find_by(version: "2026-10-08"), "retired models are deleted after the swap"
      assert_equal [[5, 6, 0.1]], RecommendationItemNeighbor.pluck(:item_id, :neighbor_id, :weight)
    end

    test "a row-count mismatch keeps the old model active and the new one loading" do
      publish(@store, "2026-10-08")
      LoadModel.call(domain: :books, store: @store)
      publish(@store, "2026-10-09", manifest_rows: 99)
      result = LoadModel.call(domain: :books, store: @store)
      assert_not result.success?
      assert_match(/99/, result.errors.first)
      assert_match(/3/, result.errors.first)
      assert_equal "2026-10-08", RecommendationModel.active_for(:books).version
      assert RecommendationModel.find_by(version: "2026-10-09").loading?
    end

    test "a stale loading row is reloaded cleanly" do
      publish(@store, "2026-10-09")
      stale = RecommendationModel.create!(domain: "books", version: "2026-10-09", state: :loading)
      stale.recommendation_item_neighbors.create!(item_id: 9, neighbor_id: 9, weight: 9.0)
      result = LoadModel.call(domain: :books, store: @store)
      assert result.data[:loaded]
      assert_equal 3, stale.reload.recommendation_item_neighbors.count
      assert stale.active?
    end

    test "an explicit version loads a hold-out model that latest does not point at" do
      publish(@store, "2026-10-09-holdout-42", latest: false)
      result = LoadModel.call(domain: :books, store: @store, version: "2026-10-09-holdout-42")
      assert result.data[:loaded]
      assert_equal "2026-10-09-holdout-42", RecommendationModel.active_for(:books).version
    end

    test "no published model is a quiet success" do
      result = LoadModel.call(domain: :books, store: @store)
      assert result.success?
      assert_not result.data[:loaded]
      assert_equal 0, RecommendationModel.count
    end
  end
end
```

```ruby
# web-app/test/sidekiq/recommendations/load_model_job_test.rb
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class LoadModelJobTest < ActiveSupport::TestCase
    test "runs on the low queue and is scheduled hourly" do
      assert_equal "low", LoadModelJob.get_sidekiq_options["queue"].to_s
      entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("recommendations_load_books")
      assert_equal "Recommendations::LoadModelJob", entry["class"]
      assert_equal "15 * * * *", entry["cron"]
      assert_equal ["books"], entry["args"]
    end

    test "loads through the default store and raises on failure" do
      Store.stubs(:default).returns(Store::Local.new(Dir.mktmpdir))
      LoadModelJob.new.perform("books")
      LoadModel.stubs(:call).returns(LoadModel::Result.new(success?: false, data: nil, errors: ["short"]))
      error = assert_raises(RuntimeError) { LoadModelJob.new.perform("books") }
      assert_includes error.message, "short"
    end
  end
end
```

- [ ] **Step 4: Run them to see them fail**

Run: `bin/rails test test/models/recommendation_model_test.rb test/models/recommendation_item_neighbor_test.rb test/lib/recommendations/load_model_test.rb test/sidekiq/recommendations/load_model_job_test.rb`
Expected: model tests pass; `uninitialized constant Recommendations::LoadModel`; schedule key missing.

- [ ] **Step 5: Implement**

```ruby
# web-app/app/lib/recommendations/load_model.rb
# frozen_string_literal: true

require "zlib"
require "csv"

module Recommendations
  # Pull a published model into Postgres (spec 2 §5). Idempotent per version:
  # the hourly job can run forever and only ever inserts a version once. The
  # swap to `active` and the retirement of the previous model happen in one
  # transaction, after the row count is checked against the manifest, so a
  # short file never replaces a good model.
  module LoadModel
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)
    BATCH = 10_000

    def self.call(domain:, store:, version: nil)
      domain = domain.to_s
      version ||= store.read_pointer(Paths.model_latest(domain))
      return skipped(version, "no model published") if version.nil?

      existing = RecommendationModel.find_by(domain: domain, version: version)
      return skipped(version, "already #{existing.state}") if existing && !existing.loading?

      manifest = JSON.parse(store.get(Paths.model_manifest(domain, version)))
      model = existing || RecommendationModel.create!(domain: domain, version: version, manifest: manifest, state: :loading)
      model.update!(manifest: manifest) if existing
      model.recommendation_item_neighbors.in_batches(of: BATCH).delete_all if existing

      rows = insert_rows(model, store.get(Paths.model(domain, version)))
      expected = manifest.fetch("rows").to_i
      if rows != expected
        return Result.new(success?: false, data: {loaded: false, version: version, rows: rows},
          errors: ["#{domain} #{version}: inserted #{rows} rows but the manifest says #{expected}; left in loading"])
      end

      RecommendationModel.transaction do
        RecommendationModel.active.where(domain: domain).where.not(id: model.id).find_each { |m| m.update!(state: :retired) }
        model.update!(state: :active)
      end
      RecommendationModel.retired.where(domain: domain).find_each do |m|
        m.recommendation_item_neighbors.in_batches(of: BATCH).delete_all
        m.destroy!
      end
      Result.new(success?: true, errors: [], data: {loaded: true, version: version, rows: rows})
    end

    def self.insert_rows(model, gzipped)
      rows = 0
      buffer = []
      flush = lambda do
        RecommendationItemNeighbor.insert_all(buffer) if buffer.any?
        rows += buffer.size
        buffer = []
      end
      csv = CSV.new(Zlib.gunzip(gzipped), headers: true)
      csv.each do |row|
        buffer << {recommendation_model_id: model.id, item_id: row["item_id"].to_i, neighbor_id: row["neighbor_id"].to_i, weight: row["weight"].to_f}
        flush.call if buffer.size >= BATCH
      end
      flush.call
      rows
    end

    def self.skipped(version, reason)
      Result.new(success?: true, errors: [], data: {loaded: false, version: version, rows: 0, reason: reason})
    end

    private_class_method :insert_rows, :skipped
  end
end
```

```ruby
# web-app/app/sidekiq/recommendations/load_model_job.rb
# frozen_string_literal: true

# Hourly (config/schedule.yml): load the model the home server last published,
# if it is new (spec 2 §5). Idempotent -- LoadModel skips a known version.
module Recommendations
  class LoadModelJob
    include Sidekiq::Job

    sidekiq_options queue: :low

    def perform(domain = "books")
      result = LoadModel.call(domain: domain, store: Store.default)
      raise "Recommendations::LoadModelJob #{domain}: #{result.errors.join(", ")}" unless result.success?

      Rails.logger.info "[Recommendations::LoadModelJob] #{domain}: #{result.data[:loaded] ? "loaded #{result.data[:version]} (#{result.data[:rows]} rows)" : "nothing to load (#{result.data[:reason]})"}"
    end
  end
end
```

Append to `web-app/config/schedule.yml`:

```yaml

recommendations_load_books:
  class: Recommendations::LoadModelJob
  cron: "15 * * * *"
  args: ["books"]
  description: "Load the latest collaborative-filtering model the home server published"
```

Append to the rake namespace:

```ruby
  desc "Load a published model into Postgres (DIR=dir for a local store, else R2; VERSION=name to load a hold-out model)"
  task load: :environment do
    store = ENV["DIR"].present? ? Recommendations::Store::Local.new(ENV["DIR"]) : Recommendations::Store.default
    result = Recommendations::LoadModel.call(domain: :books, store: store, version: ENV["VERSION"].presence)
    abort result.errors.join(", ") unless result.success?
    puts result.data[:loaded] ? "loaded #{result.data[:version]}: #{result.data[:rows]} rows" : "nothing loaded (#{result.data[:reason]})"
  end
```

- [ ] **Step 6: Run the tests and lint**

Run: `bin/rails test test/models/recommendation_model_test.rb test/models/recommendation_item_neighbor_test.rb test/lib/recommendations/load_model_test.rb test/sidekiq/recommendations/load_model_job_test.rb && bundle exec standardrb app/models/recommendation_model.rb app/models/recommendation_item_neighbor.rb app/lib/recommendations app/sidekiq/recommendations lib/tasks/recommendations.rake test/lib/recommendations test/sidekiq/recommendations test/models/recommendation_model_test.rb test/models/recommendation_item_neighbor_test.rb`
Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add web-app/db web-app/app/models/recommendation_model.rb web-app/app/models/recommendation_item_neighbor.rb web-app/app/lib/recommendations/load_model.rb web-app/app/sidekiq/recommendations/load_model_job.rb web-app/test/models/recommendation_model_test.rb web-app/test/models/recommendation_item_neighbor_test.rb web-app/test/lib/recommendations/load_model_test.rb web-app/test/sidekiq/recommendations/load_model_job_test.rb web-app/config/schedule.yml web-app/lib/tasks/recommendations.rake
git commit -m "Recommendation models: two tables, an idempotent loader with an atomic version swap"
```

---

### Task 6: Adapter and query support — `domain`, `filter_candidate_ids`, `NeighborScores`

**Files:**
- Modify: `web-app/app/lib/search/books/search/book_recommendations.rb` (`ranked_only`)
- Modify: `web-app/app/lib/recommendations/books/adapter.rb`
- Create: `web-app/app/lib/recommendations/neighbor_scores.rb`
- Test: `web-app/test/lib/search/books/search/book_recommendations_test.rb`, `web-app/test/lib/recommendations/books/adapter_test.rb`, `web-app/test/lib/recommendations/neighbor_scores_test.rb`

**Interfaces:**
- Consumes: `RecommendationModel`, `RecommendationItemNeighbor` (Task 5).
- Produces: `BookRecommendations.ranked_only(criteria:, excluded_ids:, options: {}, ids: nil)` — with `ids`, a `{ids: {values: [...]}}` filter clause is added. `Adapter#domain` → `:books`. `Adapter#filter_candidate_ids(ids, criteria:, excluded_ids:)` → `{item_id => rank_position}` for the ids that survive the ranked-pool query (empty Hash for empty input, no query). `Recommendations::NeighborScores.call(model:, shelf_ids:, excluded_ids:, limit:)` → `[{item_id:, score:, because_of:, term:}, ...]` in score order.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/search/books/search/book_recommendations_test.rb`, add (using the file's `index_book` helper and an empty criteria `::Books::RecommendationCriteria.new({})`; look at how the existing `ranked_only` test builds criteria and copy it):

```ruby
        test "ranked_only with ids returns only those ids, still filtered and rank-sorted" do
          index_book(1, ranked_position: 30)
          index_book(2, ranked_position: 10)
          index_book(3, ranked_position: 20, provisional: true)
          index_book(4, ranked_position: 5)
          criteria = ::Books::RecommendationCriteria.new({})

          hits = BookRecommendations.ranked_only(criteria: criteria, excluded_ids: [], ids: [1, 2, 3, 99])
          assert_equal [2, 1], hits.map { |h| h[:id] }, "4 is not asked for, 3 is provisional, 99 does not exist"
          assert_equal [10, 30], hits.map { |h| h[:rank_position] }

          hits = BookRecommendations.ranked_only(criteria: criteria, excluded_ids: [2], ids: [1, 2])
          assert_equal [1], hits.map { |h| h[:id] }
        end
```

In `web-app/test/lib/recommendations/books/adapter_test.rb` add:

```ruby
      test "domain names the registry key" do
        assert_equal :books, @adapter.domain
      end

      test "filter_candidate_ids asks the query only when there is something to ask" do
        assert_equal({}, @adapter.filter_candidate_ids([], criteria: ::Books::RecommendationCriteria.new({}), excluded_ids: []))
        ::Search::Books::Search::BookRecommendations.expects(:ranked_only)
          .with { |**kw| kw[:ids] == [5, 6] && kw[:options][:candidate_size] == 2 && kw[:excluded_ids] == [7] }
          .returns([{id: 6, score: 0.0, rank_position: 12}])
        kept = @adapter.filter_candidate_ids([5, 6], criteria: ::Books::RecommendationCriteria.new({}), excluded_ids: [7])
        assert_equal({6 => 12}, kept)
      end
```

```ruby
# web-app/test/lib/recommendations/neighbor_scores_test.rb
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class NeighborScoresTest < ActiveSupport::TestCase
    def setup
      @model = RecommendationModel.create!(domain: "books", version: "v", state: :active)
      other = RecommendationModel.create!(domain: "books", version: "old", state: :retired)
      [[1, 10, 0.5], [1, 11, 0.2], [2, 10, 0.4], [2, 12, 0.9], [3, 13, 0.1]].each do |i, n, w|
        @model.recommendation_item_neighbors.create!(item_id: i, neighbor_id: n, weight: w)
      end
      other.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 14, weight: 5.0)
    end

    test "sums weights per neighbour over the shelf, names the strongest contributor, and ignores other models" do
      rows = NeighborScores.call(model: @model, shelf_ids: [1, 2], excluded_ids: [], limit: 10)
      assert_equal [12, 10, 11], rows.map { |r| r[:item_id] }
      ten = rows.find { |r| r[:item_id] == 10 }
      assert_in_delta 0.9, ten[:score], 1e-9
      assert_equal 1, ten[:because_of], "item 1 contributed 0.5, item 2 contributed 0.4"
      assert_in_delta 0.5, ten[:term], 1e-9
      assert_not_includes rows.map { |r| r[:item_id] }, 14
    end

    test "excludes shelved ids and honours the limit" do
      rows = NeighborScores.call(model: @model, shelf_ids: [1, 2], excluded_ids: [12], limit: 1)
      assert_equal [10], rows.map { |r| r[:item_id] }
    end

    test "an empty shelf asks nothing" do
      assert_equal [], NeighborScores.call(model: @model, shelf_ids: [], excluded_ids: [], limit: 10)
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/search/books/search/book_recommendations_test.rb test/lib/recommendations/books/adapter_test.rb test/lib/recommendations/neighbor_scores_test.rb`
Expected: `unknown keyword: :ids`, `undefined method 'domain'`, `uninitialized constant Recommendations::NeighborScores`.

- [ ] **Step 3: Implement**

`ranked_only` in `book_recommendations.rb`:

```ruby
        # The same pool and constraints with no taste applied: the cold-start
        # fallback, the harness's rank baseline, and (with `ids`) the filter
        # the collaborative signal passes its candidates through so every
        # setting applies to that list exactly as to the taste list (spec 2 §6).
        def self.ranked_only(criteria:, excluded_ids:, options: {}, ids: nil)
          opts = Rails.application.config.x.recommendations.merge(options)
          search_criteria = criteria.to_search_criteria
          filter = CriteriaClauses.filter_clauses(search_criteria)
          filter << {ids: {values: ids.map(&:to_s)}} if ids
          extract(search({
            size: opts[:candidate_size],
            _source: false,
            docvalue_fields: ["ranked_position"],
            sort: RANK_SORT,
            query: {bool: {
              filter: filter,
              must_not: CriteriaClauses.must_not_clauses(search_criteria, excluded_ids)
            }}
          }))
        end
```

Adapter, after `attr_reader :config`:

```ruby
      def domain
        :books
      end
```

and after `rank_ordered_candidates`:

```ruby
      # The ids that survive the user's constraints, mapped to their rank
      # position (spec 2 §6 step 3). Empty in, empty out, no query.
      def filter_candidate_ids(ids, criteria:, excluded_ids:)
        return {} if ids.empty?

        ::Search::Books::Search::BookRecommendations.ranked_only(
          criteria: criteria, excluded_ids: excluded_ids, options: config.merge(candidate_size: ids.size), ids: ids
        ).to_h { |hit| [hit[:id], hit[:rank_position]] }
      end
```

```ruby
# web-app/app/lib/recommendations/neighbor_scores.rb
# frozen_string_literal: true

module Recommendations
  # The collaborative score (spec 2 §6 step 2): for every neighbour of the
  # user's shelf, the sum of the stored weights, plus the shelf book that
  # contributed most (the "because you loved" candidate) and its weight. One
  # GROUP BY through the (model, item) index; a 200-book shelf touches at most
  # 10,000 rows. Domain-agnostic: the table carries no domain, the model does.
  module NeighborScores
    def self.call(model:, shelf_ids:, excluded_ids:, limit:)
      return [] if shelf_ids.empty?

      scope = RecommendationItemNeighbor.where(recommendation_model_id: model.id, item_id: shelf_ids)
      scope = scope.where.not(neighbor_id: excluded_ids) if excluded_ids.any?
      scope.group(:neighbor_id)
        .order(Arel.sql("SUM(weight) DESC, neighbor_id ASC"))
        .limit(limit)
        .pluck(:neighbor_id, Arel.sql("SUM(weight)"), Arel.sql("(ARRAY_AGG(item_id ORDER BY weight DESC, item_id ASC))[1]"), Arel.sql("MAX(weight)"))
        .map { |id, score, because_of, term| {item_id: id, score: score.to_f, because_of: because_of, term: term.to_f} }
    end
  end
end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/search/books/search/book_recommendations_test.rb test/lib/recommendations/books/adapter_test.rb test/lib/recommendations/neighbor_scores_test.rb && bundle exec standardrb app/lib/search/books/search/book_recommendations.rb app/lib/recommendations test/lib/recommendations test/lib/search/books/search/book_recommendations_test.rb`
Expected: pass (the search test needs the local OpenSearch, as the rest of that file does).

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/search/books/search/book_recommendations.rb web-app/app/lib/recommendations/books/adapter.rb web-app/app/lib/recommendations/neighbor_scores.rb web-app/test/lib/search/books/search/book_recommendations_test.rb web-app/test/lib/recommendations/books/adapter_test.rb web-app/test/lib/recommendations/neighbor_scores_test.rb
git commit -m "Collaborative plumbing: ids filter on the ranked-pool query, neighbour scoring"
```

---

### Task 7: `Signals::Collaborative` for real, and the harness's taste-only variant and coverage

**Files:**
- Modify: `web-app/app/lib/recommendations/signals/collaborative.rb`
- Modify: `web-app/lib/tasks/recommendations.rake` (eval: a `cf` coverage column)
- Test: `web-app/test/lib/recommendations/signals_test.rb`, `web-app/test/lib/recommendations/engine_test.rb`

**Interfaces:**
- Consumes: `Interaction#trainable?(min_rating:)` (Task 2), `RecommendationModel.active_for` (Task 5), `NeighborScores.call`, `Adapter#domain`, `Adapter#filter_candidate_ids` (Task 6), knobs `collaborative`, `collaborative_min_rating`, `collaborative_overfetch`, `because_of_rating`.
- Produces: `Signals::Collaborative#available?` true only when `config[:collaborative]` and an active model exists for `adapter.domain`; `#call` returns `Candidate`s with `evidence: {because_of: id or absent, term: Float}` in collaborative-score order, at most `size`.

- [ ] **Step 1: Replace the stub test and add engine coverage**

In `web-app/test/lib/recommendations/signals_test.rb`, replace the `"collaborative is unavailable..."` test with:

```ruby
    def model_with(rows)
      model = RecommendationModel.create!(domain: "books", version: "v", state: :active)
      rows.each { |i, n, w| model.recommendation_item_neighbors.create!(item_id: i, neighbor_id: n, weight: w) }
      model
    end

    def shelf(*entries)
      entries.map { |id, kind, rating| Interaction.new(item_id: id, weight: 1.0, kind: kind, rating: rating) }
    end

    test "collaborative weight ramps with history and it is unavailable without a model or when switched off" do
      @adapter.stubs(:domain).returns(:books)
      signal = Signals::Collaborative.new(adapter: @adapter, config: @config)
      assert_not signal.available?
      assert_in_delta 0.0, signal.weight(0), 0.001
      assert_in_delta 0.5, signal.weight(10), 0.001
      assert_in_delta 200.0 / 210, signal.weight(200), 0.001

      model_with([])
      assert Signals::Collaborative.new(adapter: @adapter, config: @config).available?
      assert_not Signals::Collaborative.new(adapter: @adapter, config: Config.resolve(collaborative: false)).available?
      assert_equal :collaborative, signal.name
    end

    test "collaborative scores the trainable shelf, filters through the pool, and names a loved contributor" do
      @adapter.stubs(:domain).returns(:books)
      model_with([[1, 10, 0.5], [1, 11, 0.2], [2, 10, 0.4], [2, 12, 0.9], [3, 13, 0.3]])
      # 1 favorite, 2 read + rated 3, 3 want-to-read (never scored), 4 rated 2 (never scored)
      interactions = shelf([1, :favorite, nil], [2, :read, 3], [3, :want_to_read, nil], [4, :review, 2])
      @adapter.expects(:filter_candidate_ids).with([12, 10, 11], criteria: @criteria, excluded_ids: [7])
        .returns({12 => 40, 10 => 3})

      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: interactions, criteria: @criteria, excluded_ids: [7], size: 50)

      assert_equal [12, 10], out.map(&:item_id), "11 did not survive the pool filter"
      assert_equal [40, 3], out.map(&:rank_position)
      assert_in_delta 0.9, out[0].score, 1e-9
      assert_nil out[0].evidence[:because_of], "item 2 contributed most to 12 but is read + rated 3, below because_of_rating"
      assert_in_delta 0.9, out[0].evidence[:term], 1e-9
      assert_equal 1, out[1].evidence[:because_of], "item 1 is a favorite"
    end

    test "collaborative over-fetches by the knob and truncates to size" do
      @adapter.stubs(:domain).returns(:books)
      model = model_with([])
      (1..10).each { |n| model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 100 + n, weight: 1.0 / n) }
      NeighborScores.expects(:call).with(model: model, shelf_ids: [1], excluded_ids: [], limit: 6).returns(
        (1..6).map { |n| {item_id: 100 + n, score: 1.0 / n, because_of: 1, term: 1.0 / n} }
      )
      @adapter.stubs(:filter_candidate_ids).returns((1..6).to_h { |n| [100 + n, n] })
      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: shelf([1, :favorite, nil]), criteria: @criteria, excluded_ids: [], size: 3)
      assert_equal [101, 102, 103], out.map(&:item_id)
    end

    test "collaborative returns nothing for a shelf with no positives and never queries" do
      @adapter.stubs(:domain).returns(:books)
      model_with([[3, 13, 0.3]])
      NeighborScores.expects(:call).never
      @adapter.expects(:filter_candidate_ids).never
      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: shelf([3, :want_to_read, nil], [4, :review, 1]), criteria: @criteria, excluded_ids: [], size: 50)
      assert_equal [], out
    end
```

In `web-app/test/lib/recommendations/engine_test.rb` add one test that the engine reports the signal. Read the file first for its fake-adapter setup and copy that style; the assertion is:

```ruby
    test "the collaborative signal appears in signals_used when a model is active and the shelf has positives" do
      model = RecommendationModel.create!(domain: "books", version: "v", state: :active)
      model.recommendation_item_neighbors.create!(item_id: books_books(:war_and_peace).id, neighbor_id: books_books(:got).id, weight: 0.5)
      Recommendations::Books::Adapter.any_instance.stubs(:filter_candidate_ids).returns({books_books(:got).id => 7})
      Recommendations::Books::Adapter.any_instance.stubs(:search_candidates).returns([])
      interactions = [Interaction.new(item_id: books_books(:war_and_peace).id, weight: 2.0, kind: :favorite, rating: nil)]

      result = Engine.call(user: users(:regular_user), domain: :books, limit: 10, interactions: interactions, excluded_ids: [])

      assert result.success?
      assert_includes result.data[:signals_used], :collaborative
      assert_equal [books_books(:got).id], result.data[:items].map { |i| i[:item_id] }
      assert_equal :because_of, result.data[:items].first[:reason].type
    end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/recommendations/signals_test.rb test/lib/recommendations/engine_test.rb`
Expected: the new collaborative tests fail (`available?` false, `[]` returned).

- [ ] **Step 3: Implement**

```ruby
# web-app/app/lib/recommendations/signals/collaborative.rb
# frozen_string_literal: true

module Recommendations
  module Signals
    # Readers-like-you (spec 2 §6). Scores the user's trainable shelf against
    # the active model's neighbour rows, passes the best ids through the
    # ranked-pool query so every setting applies, and names the loved book
    # that contributed most. Unavailable without an active model for the
    # domain, or when `collaborative` is switched off (the harness's
    # taste-only variant).
    class Collaborative < Base
      def available?
        config[:collaborative] && !model.nil?
      end

      def weight(positive_count)
        n = positive_count.to_f
        n / (n + config[:collaborative_half_point])
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        shelf = interactions.select { |i| i.trainable?(min_rating: config[:collaborative_min_rating]) }
        return [] if shelf.empty? || model.nil?

        scored = NeighborScores.call(model: model, shelf_ids: shelf.map(&:item_id).uniq, excluded_ids: excluded_ids,
          limit: size * config[:collaborative_overfetch].to_i)
        return [] if scored.empty?

        kept = adapter.filter_candidate_ids(scored.map { |row| row[:item_id] }, criteria: criteria, excluded_ids: excluded_ids)
        loved = shelf.select { |i| i.kind == :favorite || (i.rating && i.rating >= config[:because_of_rating]) }.map(&:item_id).to_set

        scored.select { |row| kept.key?(row[:item_id]) }.first(size).map do |row|
          evidence = {term: row[:term]}
          evidence[:because_of] = row[:because_of] if loved.include?(row[:because_of])
          Candidate.new(item_id: row[:item_id], score: row[:score], rank_position: kept[row[:item_id]], evidence: evidence)
        end
      end

      private

      def model
        return @model if defined?(@model)

        @model = RecommendationModel.active_for(adapter.domain)
      end
    end
  end
end
```

Harness: in the `eval` task, add a `cf` count to each variant row. In the `rows` default Hash add `cf: 0`; after `row[:ms] << ms` add `row[:cf] += 1 if result.data[:signals_used].include?(:collaborative)`; in the header add `     cf` after `ms`, and in the `format` add `%6s` with `r[:cf]` (the rank baseline prints `-`: pass `name == "rank" ? "-" : r[:cf]`). Update the header comment of the rake file: `VARIANTS="collaborative=false"` is the taste-only comparison.

- [ ] **Step 4: Run the tests, lint, and a real page**

Run: `bin/rails test test/lib/recommendations/ && bundle exec standardrb app/lib/recommendations lib/tasks/recommendations.rake test/lib/recommendations`
Expected: pass. Then with the dev database and no model loaded yet: `bin/rails recommendations:show USER_ID=<any user id from the fixtures' neighbours, e.g. the id printed by a prior eval>` must print `signals: [:taste_profile]` exactly as before this task.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/recommendations/signals/collaborative.rb web-app/lib/tasks/recommendations.rake web-app/test/lib/recommendations/signals_test.rb web-app/test/lib/recommendations/engine_test.rb
git commit -m "Collaborative signal: score the shelf against the active model, filter through the pool"
```

---

### Task 8: Python package — `pairs` and `ease`

**Files:**
- Modify: `data-sources/pyproject.toml` (extra + hatch packages), `data-sources/uv.lock` (via `uv lock`), `data-sources/tests/test_packaging.py`, `.github/workflows/ci.yml` (the python install line)
- Create: `data-sources/src/recommender/__init__.py`, `pairs.py`, `ease.py`
- Test: `data-sources/tests/recommender/__init__.py` (empty), `test_pairs.py`, `test_ease.py`

**Interfaces:**
- Produces: `recommender.pairs.read_pairs(path: Path) -> Pairs(user_ids, item_ids)` (int64 arrays; `.gz` or plain CSV with the `user_id,item_id` header). `recommender.pairs.build_matrix(pairs, min_readers: int, min_positives: int = 2) -> Matrix(X: csr float32 users×items, item_index: int64 position→item id, user_index)`. `recommender.ease.fit(X, lam: float) -> np.ndarray` (float64 items×items, zero diagonal). `recommender.ease.top_neighbors(B, k) -> (rows, cols, weights)` (int64, int64, float64; per row the ≤k largest positive entries, weight descending). `recommender.ease.to_sparse(rows, cols, weights, n) -> csr`.

- [ ] **Step 1: Packaging**

In `data-sources/pyproject.toml`: under `[project.optional-dependencies]` add

```toml
# The collaborative-filtering trainer (spec 2026-10-09-book-recommendations-collaborative).
# Dense linear algebra and R2 access; never installed into the Open Library or fetcher images.
recommender = ["numpy>=2.1,<3", "scipy>=1.14,<2", "boto3>=1.35,<2"]
```

and change the hatch line to `packages = ["src/common", "src/openlibrary", "src/fetcher", "src/recommender"]`. Then run `cd data-sources && uv lock && uv sync --locked --extra fetcher --extra recommender`. In `.github/workflows/ci.yml` change the python job's install line to `uv sync --locked --extra fetcher --extra recommender` and its comment to say the recommender extra is installed so the trainer's tests run.

Append to `data-sources/tests/test_packaging.py`:

```python
import recommender


def test_recommender_is_a_sibling_source():
    assert recommender.__version__
    assert "openlibrary" not in recommender.__file__
```

```python
# data-sources/src/recommender/__init__.py
"""Collaborative filtering for The Greatest: EASE over positive shelf pairs.

Design: docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md
"""

__version__ = "0.1.0"
```

- [ ] **Step 2: Write the failing tests**

```python
# data-sources/tests/recommender/test_pairs.py
import gzip
from pathlib import Path

import numpy as np
import pytest

from recommender.pairs import Pairs, build_matrix, read_pairs


def write_csv(path: Path, rows: list[tuple[int, int]], gz: bool = True) -> Path:
    text = "user_id,item_id\n" + "".join(f"{u},{i}\n" for u, i in rows)
    if gz:
        with gzip.open(path, "wt") as f:
            f.write(text)
    else:
        path.write_text(text)
    return path


def test_read_pairs_reads_gzipped_and_plain_csv(tmp_path):
    rows = [(1, 10), (1, 11), (2, 10)]
    for name, gz in (("a.csv.gz", True), ("b.csv", False)):
        pairs = read_pairs(write_csv(tmp_path / name, rows, gz=gz))
        assert pairs.user_ids.tolist() == [1, 1, 2]
        assert pairs.item_ids.tolist() == [10, 11, 10]
        assert pairs.user_ids.dtype == np.int64


def test_read_pairs_refuses_a_foreign_header(tmp_path):
    path = tmp_path / "x.csv"
    path.write_text("item_id,user_id\n1,2\n")
    with pytest.raises(ValueError, match="header"):
        read_pairs(path)


def test_build_matrix_applies_the_item_floor_then_the_user_floor_and_dedupes():
    # items: 10 has 3 readers, 11 has 2, 12 has 1. Users: 3 keeps only item 12
    # before the floor and is dropped after it; user 4 has one positive left.
    pairs = Pairs(
        user_ids=np.array([1, 1, 2, 2, 3, 4, 4, 1]),
        item_ids=np.array([10, 11, 10, 11, 12, 10, 12, 10]),
    )
    m = build_matrix(pairs, min_readers=2, min_positives=2)
    assert m.item_index.tolist() == [10, 11]
    assert m.user_index.tolist() == [1, 2]
    assert m.X.shape == (2, 2)
    assert m.X.toarray().tolist() == [[1.0, 1.0], [1.0, 1.0]]
    assert m.X.dtype == np.float32


def test_build_matrix_keeps_a_single_positive_user_when_asked():
    pairs = Pairs(user_ids=np.array([1, 2, 2]), item_ids=np.array([10, 10, 11]))
    m = build_matrix(pairs, min_readers=1, min_positives=1)
    assert m.X.shape == (2, 2)
    assert m.X.sum() == 3
```

```python
# data-sources/tests/recommender/test_ease.py
import numpy as np
import scipy.sparse as sp

from recommender.ease import fit, to_sparse, top_neighbors

A, B, C, D, E = range(5)


def toy():
    # Six readers: A and B always together, C bridges, D and E on the other side.
    rows = [[A, B], [A, B], [A, B, C], [C, D], [C, D], [D, E]]
    X = sp.lil_matrix((len(rows), 5), dtype=np.float32)
    for u, items in enumerate(rows):
        for i in items:
            X[u, i] = 1.0
    return X.tocsr()


def test_fit_has_a_zero_diagonal_and_ranks_co_readership():
    W = fit(toy(), lam=1.0)
    assert W.shape == (5, 5)
    assert np.allclose(np.diag(W), 0.0)
    assert W[A, B] > W[A, C] > W[A, D], "B is read with A every time, C once, D never"
    assert W[D, C] > W[D, A]


def test_heavy_regularisation_shrinks_every_weight():
    W = fit(toy(), lam=1e6)
    assert np.abs(W).max() < 1e-3


def test_top_neighbors_keeps_k_positive_entries_per_row_in_descending_order():
    W = fit(toy(), lam=1.0)
    rows, cols, weights = top_neighbors(W, k=2)
    assert rows.dtype == np.int64 and cols.dtype == np.int64
    for i in range(5):
        mask = rows == i
        assert mask.sum() <= 2
        assert (weights[mask] > 0).all()
        assert (np.diff(weights[mask]) <= 0).all()
        assert i not in cols[mask]
    a = cols[rows == A]
    assert a[0] == B


def test_top_neighbors_with_k_larger_than_the_matrix():
    W = fit(toy(), lam=1.0)
    rows, cols, weights = top_neighbors(W, k=50)
    assert len(rows) == (W > 0).sum()


def test_to_sparse_round_trips():
    W = fit(toy(), lam=1.0)
    rows, cols, weights = top_neighbors(W, k=2)
    S = to_sparse(rows, cols, weights, n=5)
    assert S.shape == (5, 5)
    assert S.nnz == len(rows)
    assert np.isclose(S[A, B], W[A, B])
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd data-sources && uv run pytest tests/recommender -q`
Expected: `ModuleNotFoundError: recommender.pairs`.

- [ ] **Step 4: Implement**

```python
# data-sources/src/recommender/pairs.py
"""The export file in, a binary user×item matrix out (spec 2 §4.2).

The item floor runs first (a book needs min_readers readers to be worth a
column), then the user floor (a one-book row teaches nothing and inflates the
diagonal). One pass each, documented: a second item pass after the user pass
would move the floor by a handful of books and is not worth the surprise.
"""

from __future__ import annotations

import csv
import gzip
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import scipy.sparse as sp

HEADER = ["user_id", "item_id"]


@dataclass(frozen=True)
class Pairs:
    user_ids: np.ndarray
    item_ids: np.ndarray


@dataclass(frozen=True)
class Matrix:
    X: sp.csr_matrix
    item_index: np.ndarray
    user_index: np.ndarray


def read_pairs(path: Path) -> Pairs:
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header != HEADER:
            raise ValueError(f"{path}: expected header {HEADER}, got {header}")
        rows = np.array([(int(u), int(i)) for u, i in reader], dtype=np.int64).reshape(-1, 2)
    return Pairs(user_ids=rows[:, 0], item_ids=rows[:, 1])


def build_matrix(pairs: Pairs, min_readers: int, min_positives: int = 2) -> Matrix:
    stacked = np.unique(np.stack([pairs.user_ids, pairs.item_ids], axis=1), axis=0)
    users, items = stacked[:, 0], stacked[:, 1]

    item_vals, item_counts = np.unique(items, return_counts=True)
    keep = np.isin(items, item_vals[item_counts >= min_readers])
    users, items = users[keep], items[keep]

    user_vals, user_counts = np.unique(users, return_counts=True)
    keep = np.isin(users, user_vals[user_counts >= min_positives])
    users, items = users[keep], items[keep]

    item_index, item_codes = np.unique(items, return_inverse=True)
    user_index, user_codes = np.unique(users, return_inverse=True)
    X = sp.csr_matrix(
        (np.ones(len(users), dtype=np.float32), (user_codes, item_codes)),
        shape=(len(user_index), len(item_index)),
    )
    return Matrix(X=X, item_index=item_index, user_index=user_index)
```

```python
# data-sources/src/recommender/ease.py
"""EASE (Steck, 2019): one closed-form solve over the item gram matrix.

    G = XᵀX + λI,  P = G⁻¹,  B = −P / diag(P),  diag(B) = 0
    score(u, j) = Σ_i X[u, i] · B[i, j]

Pure numpy/scipy, no I/O. Memory is the gram matrix plus the inverse: at
18k items in float64 about 2.6 GB each, which is why the home server runs
this with a 14 GB limit and why the matrix is built in place.
"""

from __future__ import annotations

import numpy as np
import scipy.linalg
import scipy.sparse as sp


def fit(X: sp.csr_matrix, lam: float) -> np.ndarray:
    G = (X.T @ X).toarray().astype(np.float64)
    n = G.shape[0]
    G[np.diag_indices(n)] += lam
    P = scipy.linalg.inv(G, overwrite_a=True, check_finite=False)
    diag = np.diag(P).copy()
    P /= -diag[None, :]
    np.fill_diagonal(P, 0.0)
    return P


def top_neighbors(B: np.ndarray, k: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Per row, the k largest positive weights, weight descending (row = the shelf
    book, column = where it leads). Rows with no positive weight contribute nothing."""
    n = B.shape[0]
    out_rows: list[np.ndarray] = []
    out_cols: list[np.ndarray] = []
    out_weights: list[np.ndarray] = []
    for i in range(n):
        row = B[i]
        top = np.argpartition(-row, k)[:k] if k < n else np.arange(n)
        top = top[row[top] > 0]
        top = top[np.argsort(-row[top], kind="stable")]
        out_rows.append(np.full(len(top), i, dtype=np.int64))
        out_cols.append(top.astype(np.int64))
        out_weights.append(row[top].astype(np.float64))
    return (
        np.concatenate(out_rows) if out_rows else np.empty(0, dtype=np.int64),
        np.concatenate(out_cols) if out_cols else np.empty(0, dtype=np.int64),
        np.concatenate(out_weights) if out_weights else np.empty(0, dtype=np.float64),
    )


def to_sparse(rows: np.ndarray, cols: np.ndarray, weights: np.ndarray, n: int) -> sp.csr_matrix:
    return sp.csr_matrix((weights, (rows, cols)), shape=(n, n))
```

- [ ] **Step 5: Run the tests, lint, format**

Run: `cd data-sources && uv run pytest tests/recommender tests/test_packaging.py -q && uv run ruff check . && uv run ruff format --check .`
Expected: pass; format clean (run `uv run ruff format .` if not).

- [ ] **Step 6: Commit**

```bash
git add data-sources/pyproject.toml data-sources/uv.lock data-sources/src/recommender data-sources/tests/recommender data-sources/tests/test_packaging.py .github/workflows/ci.yml
git commit -m "recommender: EASE fit and top-k neighbours over the positive-pair export"
```

---

### Task 9: Python — `evaluate` and `manifest`

**Files:**
- Create: `data-sources/src/recommender/evaluate.py`, `manifest.py`
- Test: `data-sources/tests/recommender/test_evaluate.py`, `test_manifest.py`

**Interfaces:**
- Consumes: `ease.fit`, `ease.top_neighbors`, `ease.to_sparse`.
- Produces: `evaluate.hold_one_out(X, seed, min_positives=5) -> Split(train: csr, users: int64 row indices, held: int64 item positions)`. `evaluate.metrics(train, model: csr, users, held, k_hit=10, k_recall=50, batch=2000) -> {"users": int, "hit_at_10": float, "recall_at_50": float}`. `manifest.build(**fields) -> dict`. `manifest.gate(new, previous, ratio) -> (ok: bool, reason: str)`.

- [ ] **Step 1: Write the failing tests**

```python
# data-sources/tests/recommender/test_evaluate.py
import numpy as np
import scipy.sparse as sp

from recommender.evaluate import hold_one_out, metrics


def matrix(rows):
    X = sp.lil_matrix((len(rows), 6), dtype=np.float32)
    for u, items in enumerate(rows):
        for i in items:
            X[u, i] = 1.0
    return X.tocsr()


def test_hold_one_out_hides_one_positive_per_eligible_user_deterministically():
    X = matrix([[0, 1, 2], [0, 1, 2, 3], [4], [0, 1, 2, 3, 4]])
    a = hold_one_out(X, seed=3, min_positives=3)
    b = hold_one_out(X, seed=3, min_positives=3)
    assert a.users.tolist() == [0, 1, 3]
    assert a.held.tolist() == b.held.tolist()
    for u, h in zip(a.users, a.held, strict=True):
        assert X[u, h] == 1.0
        assert a.train[u, h] == 0.0
        assert a.train[u].sum() == X[u].sum() - 1
    assert a.train[2].sum() == 1.0, "ineligible users keep everything"


def test_metrics_count_a_held_item_in_the_top_k_and_never_recommend_seen_items():
    train = matrix([[0, 1], [2, 3]])
    # item 0 leads to 4 strongly, 1 leads to 5; item 2 leads to 1 (seen by nobody in row 1) and 3 leads to 0
    model = sp.csr_matrix(
        (np.array([0.9, 0.5, 0.7, 0.2]), (np.array([0, 1, 2, 3]), np.array([4, 5, 1, 0]))), shape=(6, 6)
    )
    users = np.array([0, 1])
    held = np.array([4, 1])
    out = metrics(train, model, users, held, k_hit=1, k_recall=2)
    assert out["users"] == 2
    assert out["hit_at_10"] == 1.0, "user 0's top-1 is item 4; user 1's top-1 is item 1"
    assert out["recall_at_50"] == 1.0
    out = metrics(train, model, users, np.array([5, 0]), k_hit=1, k_recall=2)
    assert out["hit_at_10"] == 0.5
    assert out["recall_at_50"] == 1.0


def test_metrics_mask_seen_items():
    train = matrix([[0, 1]])
    model = sp.csr_matrix((np.array([5.0, 0.1]), (np.array([0, 1]), np.array([1, 2]))), shape=(6, 6))
    out = metrics(train, model, np.array([0]), np.array([2]), k_hit=1, k_recall=1)
    assert out["hit_at_10"] == 1.0, "item 1 scores highest but is already on the shelf"


def test_metrics_with_no_users():
    out = metrics(matrix([[0]]), sp.csr_matrix((6, 6)), np.array([], dtype=np.int64), np.array([], dtype=np.int64))
    assert out == {"users": 0, "hit_at_10": 0.0, "recall_at_50": 0.0}
```

```python
# data-sources/tests/recommender/test_manifest.py
from recommender.manifest import build, gate


def manifest(hit):
    return build(
        domain="books", export="2026-10-09", lam=500.0, min_readers=5, top_k=50,
        users=10, items=5, rows=20, eval_result={"seed": 1, "users": 8, "hit_at_10": hit, "recall_at_50": hit},
        previous=None,
    )


def test_build_carries_every_field_and_a_timestamp():
    m = manifest(0.3)
    assert m["domain"] == "books" and m["export"] == "2026-10-09"
    assert m["lambda"] == 500.0 and m["min_readers"] == 5 and m["top_k"] == 50
    assert m["users"] == 10 and m["items"] == 5 and m["rows"] == 20
    assert m["eval"]["hit_at_10"] == 0.3
    assert m["trained_at"].endswith("Z")
    assert m["previous"] is None


def test_gate_passes_without_a_previous_model_or_evaluation():
    assert gate(manifest(0.1), None, 0.9) == (True, "no previous model")
    ok, reason = gate(manifest(0.1), {"eval": {}}, 0.9)
    assert ok and "no evaluation" in reason


def test_gate_compares_hit_at_10_against_the_ratio():
    ok, _ = gate(manifest(0.27), manifest(0.30), 0.9)
    assert ok
    ok, reason = gate(manifest(0.26), manifest(0.30), 0.9)
    assert not ok
    assert "0.260" in reason and "0.300" in reason
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd data-sources && uv run pytest tests/recommender -q`
Expected: `ModuleNotFoundError` for `recommender.evaluate` and `recommender.manifest`.

- [ ] **Step 3: Implement**

```python
# data-sources/src/recommender/evaluate.py
"""The trainer's own measurement (spec 2 §8.1): hide one positive per user
with enough history, fit on the rest, and ask whether it comes back in the
top 10 and top 50. This tunes λ, the reader floor and k where the model is
built; the Rails harness measures the fused page and owns the bar."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import scipy.sparse as sp


@dataclass(frozen=True)
class Split:
    train: sp.csr_matrix
    users: np.ndarray
    held: np.ndarray


def hold_one_out(X: sp.csr_matrix, seed: int, min_positives: int = 5) -> Split:
    X = X.tocsr(copy=True)
    X.sort_indices()
    counts = np.diff(X.indptr)
    users = np.flatnonzero(counts >= min_positives).astype(np.int64)
    rng = np.random.default_rng(seed)
    positions = np.array(
        [rng.integers(X.indptr[u], X.indptr[u + 1]) for u in users], dtype=np.int64
    )
    held = X.indices[positions].astype(np.int64) if len(users) else np.empty(0, dtype=np.int64)
    train = X.copy()
    train.data[positions] = 0
    train.eliminate_zeros()
    return Split(train=train, users=users, held=held)


def metrics(
    train: sp.csr_matrix,
    model: sp.csr_matrix,
    users: np.ndarray,
    held: np.ndarray,
    k_hit: int = 10,
    k_recall: int = 50,
    batch: int = 2000,
) -> dict:
    if len(users) == 0:
        return {"users": 0, "hit_at_10": 0.0, "recall_at_50": 0.0}
    n_items = train.shape[1]
    k = min(k_recall, n_items)
    hits = 0
    recalls = 0
    for start in range(0, len(users), batch):
        rows = users[start : start + batch]
        scores = (train[rows] @ model).toarray()
        scores[train[rows].toarray() > 0] = -np.inf
        top = np.argpartition(-scores, k - 1, axis=1)[:, :k] if k < n_items else np.tile(np.arange(n_items), (len(rows), 1))
        order = np.argsort(-np.take_along_axis(scores, top, axis=1), axis=1, kind="stable")
        top = np.take_along_axis(top, order, axis=1)
        target = held[start : start + batch][:, None]
        hits += int(np.any(top[:, :k_hit] == target, axis=1).sum())
        recalls += int(np.any(top == target, axis=1).sum())
    return {
        "users": int(len(users)),
        "hit_at_10": hits / len(users),
        "recall_at_50": recalls / len(users),
    }
```

```python
# data-sources/src/recommender/manifest.py
"""What a published model says about itself, and the gate that decides
whether it replaces the previous one (spec 2 §4.3)."""

from __future__ import annotations

from datetime import UTC, datetime


def build(
    *,
    domain: str,
    export: str,
    lam: float,
    min_readers: int,
    top_k: int,
    users: int,
    items: int,
    rows: int,
    eval_result: dict,
    previous: str | None,
) -> dict:
    return {
        "domain": domain,
        "export": export,
        "trained_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lambda": float(lam),
        "min_readers": int(min_readers),
        "top_k": int(top_k),
        "users": int(users),
        "items": int(items),
        "rows": int(rows),
        "eval": dict(eval_result),
        "previous": previous,
    }


def gate(new: dict, previous: dict | None, ratio: float) -> tuple[bool, str]:
    if previous is None:
        return True, "no previous model"
    old = (previous.get("eval") or {}).get("hit_at_10")
    if not old:
        return True, "previous model has no evaluation"
    fresh = new["eval"]["hit_at_10"]
    if fresh >= ratio * old:
        return True, f"hit@10 {fresh:.3f} vs previous {old:.3f}"
    return False, f"hit@10 {fresh:.3f} is below {ratio:.2f} x previous {old:.3f}"
```

- [ ] **Step 4: Run the tests, lint, format**

Run: `cd data-sources && uv run pytest tests/recommender -q && uv run ruff check . && uv run ruff format --check .`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add data-sources/src/recommender/evaluate.py data-sources/src/recommender/manifest.py data-sources/tests/recommender/test_evaluate.py data-sources/tests/recommender/test_manifest.py
git commit -m "recommender: hold-one-out evaluation and the manifest publish gate"
```

---

### Task 10: Python — `store`, `train`, the CLI, the image and the compose service

**Files:**
- Create: `data-sources/src/recommender/store.py`, `train.py`, `cli.py`, `data-sources/recommender.Dockerfile`
- Modify: `data-sources/docker-compose.yml`, `data-sources/README.md`
- Test: `data-sources/tests/recommender/test_store.py`, `test_cli.py`

**Interfaces:**
- Consumes: `pairs`, `ease`, `evaluate`, `manifest` (Tasks 8–9).
- Produces: `store.keys` functions (`interactions_key(domain, name)`, `interactions_latest(domain)`, `model_key(domain, version)`, `manifest_key(domain, version)`, `model_latest(domain)`), `store.Missing`, `store.Local(root)`, `store.R2(client, bucket)` + `R2.from_env()`, each with `get(key) -> bytes`, `put(key, data: bytes)`, `exists(key)`, `read_pointer(key) -> str | None`, `write_pointer(key, value)`. `train.train_model(input_path, *, domain, export_name, lam, min_readers, top_k, eval_seed, previous) -> TrainResult(csv_gz: bytes, manifest: dict)`. CLI `python -m recommender.cli train|run`.

- [ ] **Step 1: Write the failing tests**

```python
# data-sources/tests/recommender/test_store.py
from pathlib import Path

import pytest
from botocore.exceptions import ClientError

from recommender import store
from recommender.store import R2, Local, Missing


def test_keys_match_the_rails_side():
    assert store.interactions_key("books", "2026-10-09") == "recommendations/books/interactions/2026-10-09.csv.gz"
    assert store.interactions_latest("books") == "recommendations/books/interactions/latest"
    assert store.model_key("books", "v") == "recommendations/books/model/v.csv.gz"
    assert store.manifest_key("books", "v") == "recommendations/books/model/v.json"
    assert store.model_latest("books") == "recommendations/books/model/latest"


def test_local_round_trip(tmp_path: Path):
    s = Local(tmp_path)
    assert not s.exists("a/b")
    assert s.read_pointer("a/latest") is None
    with pytest.raises(Missing):
        s.get("a/b")
    s.put("a/b", b"\x00bytes")
    assert s.exists("a/b") and s.get("a/b") == b"\x00bytes"
    s.write_pointer("a/latest", "b")
    assert s.read_pointer("a/latest") == "b"
    assert (tmp_path / "a/latest").read_text() == "b\n"


class FakeClient:
    def __init__(self):
        self.objects: dict[tuple[str, str], bytes] = {}

    def put_object(self, Bucket, Key, Body):
        self.objects[(Bucket, Key)] = Body

    def get_object(self, Bucket, Key):
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "NoSuchKey"}}, "GetObject")
        import io

        return {"Body": io.BytesIO(self.objects[(Bucket, Key)])}

    def head_object(self, Bucket, Key):
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
        return {}


def test_r2_uses_the_bucket_and_translates_missing_keys():
    client = FakeClient()
    s = R2(client, "tg-recs")
    assert not s.exists("k")
    assert s.read_pointer("k") is None
    with pytest.raises(Missing):
        s.get("k")
    s.put("k", b"v")
    assert client.objects[("tg-recs", "k")] == b"v"
    assert s.exists("k") and s.get("k") == b"v"
    s.write_pointer("p", "x")
    assert s.read_pointer("p") == "x"


def test_r2_from_env_requires_all_four(monkeypatch):
    for key in R2.ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    assert R2.from_env() is None
    monkeypatch.setenv("RECOMMENDER_R2_ACCOUNT_ID", "acct")
    with pytest.raises(RuntimeError, match="RECOMMENDER_R2"):
        R2.from_env()
```

```python
# data-sources/tests/recommender/test_cli.py
import gzip
import json
from pathlib import Path

from typer.testing import CliRunner

from recommender import store
from recommender.cli import app

runner = CliRunner()

ROWS = [
    (1, 10), (1, 11), (1, 12), (1, 13), (1, 14),
    (2, 10), (2, 11), (2, 12), (2, 13), (2, 15),
    (3, 10), (3, 11), (3, 12), (3, 14), (3, 15),
    (4, 13), (4, 14), (4, 15), (4, 16), (4, 10),
    (5, 13), (5, 14), (5, 15), (5, 16), (5, 11),
    (6, 10), (6, 12), (6, 16), (6, 14), (6, 13),
]


def export(path: Path, rows=ROWS) -> Path:
    with gzip.open(path, "wt") as f:
        f.write("user_id,item_id\n" + "".join(f"{u},{i}\n" for u, i in rows))
    return path


def read_model(path: Path):
    lines = gzip.open(path, "rt").read().splitlines()
    assert lines[0] == "item_id,neighbor_id,weight"
    return [(int(a), int(b), float(c)) for a, b, c in (line.split(",") for line in lines[1:])]


def test_train_writes_a_sorted_model_and_a_manifest(tmp_path: Path):
    src = export(tmp_path / "2026-10-09.csv.gz")
    out = tmp_path / "model"
    result = runner.invoke(app, ["train", "--input", str(src), "--output-dir", str(out), "--name", "2026-10-09",
                                 "--lambda", "1", "--min-readers", "2", "--top-k", "3", "--eval-seed", "1"])
    assert result.exit_code == 0, result.output
    rows = read_model(out / "2026-10-09.csv.gz")
    assert rows == sorted(rows, key=lambda r: (r[0], -r[2]))
    assert all(w > 0 for _, _, w in rows)
    assert max(sum(1 for r in rows if r[0] == i) for i in {r[0] for r in rows}) <= 3
    manifest = json.loads((out / "2026-10-09.json").read_text())
    assert manifest["rows"] == len(rows)
    assert manifest["export"] == "2026-10-09" and manifest["lambda"] == 1.0
    assert manifest["items"] == 7 and manifest["users"] == 6
    assert 0.0 <= manifest["eval"]["hit_at_10"] <= 1.0
    assert "hit@10" in result.output


def test_run_pulls_latest_trains_pushes_and_moves_the_pointer(tmp_path: Path):
    root = tmp_path / "store"
    s = store.Local(root)
    s.put(store.interactions_key("books", "2026-10-09"), (export(tmp_path / "e.csv.gz")).read_bytes())
    s.write_pointer(store.interactions_latest("books"), "2026-10-09")
    work = tmp_path / "work"
    result = runner.invoke(app, ["run", "--store-dir", str(root), "--work-dir", str(work), "--lambda", "1",
                                 "--min-readers", "2", "--top-k", "3", "--max-export-age-days", "100000"])
    assert result.exit_code == 0, result.output
    assert s.read_pointer(store.model_latest("books")) == "2026-10-09"
    assert s.exists(store.model_key("books", "2026-10-09"))
    manifest = json.loads(s.get(store.manifest_key("books", "2026-10-09")))
    assert manifest["previous"] is None

    again = runner.invoke(app, ["run", "--store-dir", str(root), "--work-dir", str(work), "--max-export-age-days", "100000"])
    assert again.exit_code == 0 and "already trained" in again.output


def test_run_keeps_the_pointer_when_the_gate_fails(tmp_path: Path):
    root = tmp_path / "store"
    s = store.Local(root)
    s.put(store.interactions_key("books", "2026-10-09"), (export(tmp_path / "e.csv.gz")).read_bytes())
    s.write_pointer(store.interactions_latest("books"), "2026-10-09")
    s.put(store.manifest_key("books", "2026-10-01"), json.dumps({"eval": {"hit_at_10": 1.0}}).encode())
    s.write_pointer(store.model_latest("books"), "2026-10-01")
    result = runner.invoke(app, ["run", "--store-dir", str(root), "--work-dir", str(tmp_path / "w"), "--lambda", "1",
                                 "--min-readers", "2", "--top-k", "3", "--max-export-age-days", "100000"])
    assert result.exit_code == 1
    assert "below" in result.output
    assert s.read_pointer(store.model_latest("books")) == "2026-10-01"
    assert s.exists(store.model_key("books", "2026-10-09")), "the files stay for inspection"


def test_run_refuses_a_stale_export(tmp_path: Path):
    root = tmp_path / "store"
    s = store.Local(root)
    s.put(store.interactions_key("books", "2020-01-01"), (export(tmp_path / "e.csv.gz")).read_bytes())
    s.write_pointer(store.interactions_latest("books"), "2020-01-01")
    result = runner.invoke(app, ["run", "--store-dir", str(root), "--work-dir", str(tmp_path / "w")])
    assert result.exit_code == 1
    assert "older than" in result.output
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd data-sources && uv run pytest tests/recommender -q`
Expected: `ModuleNotFoundError` for `recommender.store`, `recommender.cli`.

- [ ] **Step 3: Implement**

```python
# data-sources/src/recommender/store.py
"""Where exports and models live (spec 2 §2): a directory for development
and tests, a private R2 bucket on the home server. Bytes and one-line
pointers only. The five key shapes mirror Recommendations::Paths in Rails;
change both or neither."""

from __future__ import annotations

import os
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

_MISSING_CODES = {"NoSuchKey", "404", "NotFound"}


class Missing(Exception):
    pass


def interactions_key(domain: str, name: str) -> str:
    return f"recommendations/{domain}/interactions/{name}.csv.gz"


def interactions_latest(domain: str) -> str:
    return f"recommendations/{domain}/interactions/latest"


def model_key(domain: str, version: str) -> str:
    return f"recommendations/{domain}/model/{version}.csv.gz"


def manifest_key(domain: str, version: str) -> str:
    return f"recommendations/{domain}/model/{version}.json"


def model_latest(domain: str) -> str:
    return f"recommendations/{domain}/model/latest"


class Local:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    def put(self, key: str, data: bytes) -> None:
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def get(self, key: str) -> bytes:
        path = self.root / key
        if not path.is_file():
            raise Missing(key)
        return path.read_bytes()

    def exists(self, key: str) -> bool:
        return (self.root / key).is_file()

    def read_pointer(self, key: str) -> str | None:
        if not self.exists(key):
            return None
        return self.get(key).decode().strip() or None

    def write_pointer(self, key: str, value: str) -> None:
        self.put(key, f"{value}\n".encode())


class R2:
    ENV_KEYS = (
        "RECOMMENDER_R2_ACCOUNT_ID",
        "RECOMMENDER_R2_ACCESS_KEY",
        "RECOMMENDER_R2_SECRET_KEY",
        "RECOMMENDER_R2_BUCKET",
    )

    def __init__(self, client, bucket: str) -> None:
        self.client = client
        self.bucket = bucket

    @classmethod
    def from_env(cls) -> R2 | None:
        values = [os.environ.get(k) or None for k in cls.ENV_KEYS]
        if all(v is None for v in values):
            return None
        if any(v is None for v in values):
            raise RuntimeError(f"{', '.join(cls.ENV_KEYS)} must all be set or all be unset")
        account, access, secret, bucket = values
        client = boto3.client(
            "s3",
            endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
            aws_access_key_id=access,
            aws_secret_access_key=secret,
            region_name="auto",
        )
        return cls(client, bucket)

    def put(self, key: str, data: bytes) -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data)

    def get(self, key: str) -> bytes:
        try:
            return self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read()
        except ClientError as error:
            if error.response["Error"]["Code"] in _MISSING_CODES:
                raise Missing(key) from error
            raise

    def exists(self, key: str) -> bool:
        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError as error:
            if error.response["Error"]["Code"] in _MISSING_CODES:
                return False
            raise

    def read_pointer(self, key: str) -> str | None:
        try:
            return self.get(key).decode().strip() or None
        except Missing:
            return None

    def write_pointer(self, key: str, value: str) -> None:
        self.put(key, f"{value}\n".encode())
```

```python
# data-sources/src/recommender/train.py
"""Export file in, model file and manifest out (spec 2 §4.2–4.3). Two fits:
one on the hold-one-out split for the manifest's evaluation, one on
everything for the published model."""

from __future__ import annotations

import csv
import gzip
import io
from dataclasses import dataclass
from pathlib import Path

from . import ease, evaluate, manifest, pairs


@dataclass(frozen=True)
class TrainResult:
    csv_gz: bytes
    manifest: dict


def train_model(
    input_path: Path,
    *,
    domain: str,
    export_name: str,
    lam: float,
    min_readers: int,
    top_k: int,
    eval_seed: int,
    previous: str | None,
) -> TrainResult:
    matrix = pairs.build_matrix(pairs.read_pairs(input_path), min_readers=min_readers)
    n_items = matrix.X.shape[1]

    split = evaluate.hold_one_out(matrix.X, seed=eval_seed)
    eval_rows, eval_cols, eval_weights = ease.top_neighbors(ease.fit(split.train, lam), top_k)
    eval_result = evaluate.metrics(
        split.train, ease.to_sparse(eval_rows, eval_cols, eval_weights, n_items), split.users, split.held
    )
    eval_result = {"seed": eval_seed, **eval_result}

    rows, cols, weights = ease.top_neighbors(ease.fit(matrix.X, lam), top_k)
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb") as gz:
        text = io.TextIOWrapper(gz, encoding="utf-8", newline="")
        writer = csv.writer(text)
        writer.writerow(["item_id", "neighbor_id", "weight"])
        item_ids = matrix.item_index[rows]
        neighbor_ids = matrix.item_index[cols]
        for item_id, neighbor_id, weight in zip(item_ids, neighbor_ids, weights, strict=True):
            writer.writerow([int(item_id), int(neighbor_id), f"{weight:.6g}"])
        text.flush()
        text.detach()

    built = manifest.build(
        domain=domain,
        export=export_name,
        lam=lam,
        min_readers=min_readers,
        top_k=top_k,
        users=matrix.X.shape[0],
        items=n_items,
        rows=len(rows),
        eval_result=eval_result,
        previous=previous,
    )
    return TrainResult(csv_gz=buffer.getvalue(), manifest=built)
```

```python
# data-sources/src/recommender/cli.py
"""The two entry points (spec 2 §4.1).

    train   files in, files out -- development and the harness loop
    run     store in, store out -- what the home server's timer executes:
            pull `latest`, train, gate against the previous manifest, push,
            move the pointer only on a pass
"""

from __future__ import annotations

import json
from datetime import UTC, date, datetime
from pathlib import Path

import typer

from . import manifest as manifest_mod
from . import store as store_mod
from .train import train_model

app = typer.Typer(add_completion=False)

LAMBDA = typer.Option(500.0, "--lambda", help="EASE regularisation")
MIN_READERS = typer.Option(5, help="Drop books with fewer readers")
TOP_K = typer.Option(50, help="Neighbours kept per book")
EVAL_SEED = typer.Option(1, help="Seed for the hold-one-out evaluation")
GATE_RATIO = typer.Option(0.9, help="New hit@10 must be at least this × the previous model's")


def _report(result_manifest: dict) -> None:
    e = result_manifest["eval"]
    typer.echo(
        f"{result_manifest['export']}: {result_manifest['users']} users, {result_manifest['items']} items, "
        f"{result_manifest['rows']} rows; hit@10 {e['hit_at_10']:.3f} recall@50 {e['recall_at_50']:.3f} "
        f"over {e['users']} users"
    )


@app.command()
def train(
    input: Path = typer.Option(..., exists=True, dir_okay=False),
    output_dir: Path = typer.Option(..., file_okay=False),
    name: str = typer.Option(..., help="Model version; the export name it was trained on"),
    domain: str = typer.Option("books"),
    lam: float = LAMBDA,
    min_readers: int = MIN_READERS,
    top_k: int = TOP_K,
    eval_seed: int = EVAL_SEED,
) -> None:
    result = train_model(
        input, domain=domain, export_name=name, lam=lam, min_readers=min_readers,
        top_k=top_k, eval_seed=eval_seed, previous=None,
    )
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / f"{name}.csv.gz").write_bytes(result.csv_gz)
    (output_dir / f"{name}.json").write_text(json.dumps(result.manifest, indent=2) + "\n")
    _report(result.manifest)


def _export_date(name: str) -> date:
    try:
        return date.fromisoformat(name[:10])
    except ValueError as error:
        raise typer.BadParameter(f"export name {name!r} does not start with a date") from error


@app.command()
def run(
    domain: str = typer.Option("books"),
    store_dir: Path | None = typer.Option(None, help="A local store instead of R2 (tests, development)"),
    work_dir: Path = typer.Option(Path("/work"), file_okay=False),
    lam: float = LAMBDA,
    min_readers: int = MIN_READERS,
    top_k: int = TOP_K,
    eval_seed: int = EVAL_SEED,
    gate_ratio: float = GATE_RATIO,
    max_export_age_days: int = typer.Option(3, help="Refuse an export older than this"),
) -> None:
    store = store_mod.Local(store_dir) if store_dir else store_mod.R2.from_env()
    if store is None:
        typer.echo("no store: pass --store-dir or set the RECOMMENDER_R2_* variables")
        raise typer.Exit(1)

    name = store.read_pointer(store_mod.interactions_latest(domain))
    if name is None:
        typer.echo(f"no export published for {domain}")
        raise typer.Exit(1)
    age = (datetime.now(UTC).date() - _export_date(name)).days
    if age > max_export_age_days:
        typer.echo(f"export {name} is older than {max_export_age_days} days ({age}); not training")
        raise typer.Exit(1)

    previous = store.read_pointer(store_mod.model_latest(domain))
    if previous == name:
        typer.echo(f"{name} already trained; nothing to do")
        return
    previous_manifest = (
        json.loads(store.get(store_mod.manifest_key(domain, previous))) if previous else None
    )

    work_dir.mkdir(parents=True, exist_ok=True)
    input_path = work_dir / f"{name}.csv.gz"
    input_path.write_bytes(store.get(store_mod.interactions_key(domain, name)))

    result = train_model(
        input_path, domain=domain, export_name=name, lam=lam, min_readers=min_readers,
        top_k=top_k, eval_seed=eval_seed, previous=previous,
    )
    store.put(store_mod.model_key(domain, name), result.csv_gz)
    store.put(store_mod.manifest_key(domain, name), (json.dumps(result.manifest, indent=2) + "\n").encode())
    _report(result.manifest)

    ok, reason = manifest_mod.gate(result.manifest, previous_manifest, gate_ratio)
    if not ok:
        typer.echo(f"gate failed: {reason}; latest stays {previous}")
        raise typer.Exit(1)
    store.write_pointer(store_mod.model_latest(domain), name)
    typer.echo(f"published {name} ({reason})")


if __name__ == "__main__":
    app()
```

```dockerfile
# data-sources/recommender.Dockerfile
# The collaborative-filtering trainer (spec 2026-10-09-book-recommendations-collaborative).
# Its own image so the Open Library API never carries numpy/scipy, and this
# one never carries DuckDB's data or a browser. Runs as a one-shot job.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --extra recommender --no-install-project

COPY src/ ./src/
RUN uv sync --locked --no-dev --extra recommender

ENV PATH="/app/.venv/bin:$PATH"

RUN useradd --create-home --uid 10001 recommender \
 && mkdir -p /work && chown recommender /work
USER recommender

ENTRYPOINT ["python", "-m", "recommender.cli"]
CMD ["run"]
```

Append to `data-sources/docker-compose.yml` under `services:`:

```yaml
  # The collaborative-filtering trainer (docs/features/recommendations.md,
  # "Collaborative signal"). A one-shot job the ol VM's timer runs with
  # `compose run --rm recommender`; the profile keeps `compose up` from
  # starting it. Memory and CPU limits live in deployment/home-server/compose.ol.yml.
  recommender:
    build:
      context: .
      dockerfile: recommender.Dockerfile
    image: the-greatest/recommender:latest
    profiles: ["recommender"]
    environment:
      RECOMMENDER_R2_ACCOUNT_ID: "${RECOMMENDER_R2_ACCOUNT_ID:-}"
      RECOMMENDER_R2_ACCESS_KEY: "${RECOMMENDER_R2_ACCESS_KEY:-}"
      RECOMMENDER_R2_SECRET_KEY: "${RECOMMENDER_R2_SECRET_KEY:-}"
      RECOMMENDER_R2_BUCKET: "${RECOMMENDER_R2_BUCKET:-}"
    volumes:
      - recommender-work:/work
```

and at the end of the file:

```yaml
volumes:
  recommender-work:
```

Add a `## Running the recommender` section to `data-sources/README.md` after the fetcher section:

````markdown
## Running the recommender

The collaborative-filtering trainer for book recommendations
(`docs/features/recommendations.md`, "Collaborative signal"). Install with the
`recommender` extra; it is never part of the Open Library or fetcher images.

```bash
uv sync --locked --extra fetcher --extra recommender
# files in, files out (development, the Rails harness loop):
uv run python -m recommender.cli train --input <export.csv.gz> --output-dir <dir> --name <export-name>
# store in, store out (what the home server's timer runs; --store-dir for a local store):
uv run python -m recommender.cli run --store-dir <dir> --work-dir /tmp/recommender
```

`train` writes `<name>.csv.gz` (`item_id,neighbor_id,weight`) and `<name>.json`
(the manifest, including the trainer's own hold-one-out hit@10 and recall@50).
`run` pulls the latest export, refuses one older than `--max-export-age-days`,
trains, pushes, and moves the `latest` pointer only when the new model's hit@10
is at least `--gate-ratio` × the previous model's. The image:
`docker compose --profile recommender build recommender`.
````

- [ ] **Step 4: Run the tests, lint, format, and build the image**

Run: `cd data-sources && uv run pytest -q && uv run ruff check . && uv run ruff format --check . && docker compose --profile recommender build recommender`
Expected: all pass; the image builds. If `uv run pytest` fails on existing tests that need an artifact, those are marked `artifact` and skip without `OL_DATA_ROOT`; a failure elsewhere is this task's to fix.

- [ ] **Step 5: Commit**

```bash
git add data-sources/src/recommender/store.py data-sources/src/recommender/train.py data-sources/src/recommender/cli.py data-sources/recommender.Dockerfile data-sources/docker-compose.yml data-sources/README.md data-sources/tests/recommender/test_store.py data-sources/tests/recommender/test_cli.py
git commit -m "recommender: store, trainer CLI with the publish gate, image and compose service"
```

---

### Task 11: Measure against the bar, record it, document the signal

**Files:**
- Create: `docs/data-quality/recommendations-collaborative-2026-10-09.md`
- Modify: `docs/features/recommendations.md` (new "Collaborative signal" section; Harness, Knobs, Known gaps updated), `docs/launch-todo.md` (§2, a new numbered item after item 10), `web-app/config/initializers/recommendations.rb` (only if the bar fails: `collaborative: false`)
- Test: none new; `docs/data-quality` records are measurements

**Interfaces:**
- Consumes: everything above. Needs the development database, the local OpenSearch with the books index built, and `uv` with the recommender extra.

- [ ] **Step 1: Export with the harness hold-out, seed 42**

```bash
cd web-app
bin/rails recommendations:export DIR=tmp/recommendations HOLDOUT_SEED=42 HOLDOUT_USERS=300 HOLDOUT_FRACTION=0.2
```

Expected: prints the hold-out size and `wrote ~3,000,000 rows to recommendations/books/interactions/<date>-holdout-42.csv.gz (pointer not moved)`. Note the name; call it `$NAME` below.

- [ ] **Step 2: Sweep λ and the reader floor in the trainer**

```bash
cd ../data-sources
for lam in 100 300 500 1000 3000; do
  uv run python -m recommender.cli train --input ../web-app/tmp/recommendations/recommendations/books/interactions/$NAME.csv.gz \
    --output-dir /tmp/recommender-sweep/lam-$lam --name $NAME --lambda $lam --min-readers 5
done
uv run python -m recommender.cli train --input ../web-app/tmp/recommendations/recommendations/books/interactions/$NAME.csv.gz \
  --output-dir /tmp/recommender-sweep/readers-10 --name $NAME --lambda 500 --min-readers 10
```

Expected: six lines of `hit@10 … recall@50 …`, each run one to three minutes and under 10 GB on this machine (watch with `free -g` in a second shell). Record the six rows in the data-quality file's first table. Pick the λ with the best hit@10 at `min-readers 5`; if it is not 500, use it as `--lambda` in the next step and note it as the proposed default.

- [ ] **Step 3: Train the chosen model into the local store and load it**

```bash
uv run python -m recommender.cli train --input ../web-app/tmp/recommendations/recommendations/books/interactions/$NAME.csv.gz \
  --output-dir ../web-app/tmp/recommendations/recommendations/books/model --name $NAME --lambda <chosen>
cd ../web-app
bin/rails recommendations:load DIR=tmp/recommendations VERSION=$NAME
```

Expected: `loaded <name>: ~900,000 rows`.

- [ ] **Step 4: Measure the fused page against today's defaults**

```bash
bin/rails recommendations:eval USERS=300 SEED=42 FRACTION=0.2 VARIANTS="collaborative=false" | tee /tmp/recommender-sweep/eval-42.txt
```

Expected: per segment, rows `rank`, `shipped defaults` (taste + collaborative; `cf` column shows how many users the signal fired for), `collaborative=false` (today's engine), and the frequency baseline. The bar (spec 2 §8.2): on 20–99 and 100+, defaults beat `collaborative=false` on hit@10 and recall@50 beyond noise; 5–19 not worse beyond noise; mean rank within 2×; KL no worse. Noise band: run `SEED=43` on the same loaded model only if the margin is under about 0.03; the hold-out users differ, so that run's numbers are a second sample, not a repeat.

- [ ] **Step 5: A second sample, seed 7**

Repeat Steps 1, 3 (chosen λ only) and 4 with `HOLDOUT_SEED=7` / `SEED=7`. Two samples, both tables in the record.

- [ ] **Step 6: Leave the development database serving a full model**

```bash
bin/rails recommendations:export DIR=tmp/recommendations
cd ../data-sources && uv run python -m recommender.cli run --store-dir ../web-app/tmp/recommendations --work-dir /tmp/recommender-work --lambda <chosen>
cd ../web-app && bin/rails recommendations:load DIR=tmp/recommendations
bin/rails recommendations:show USER_ID=<a 100+ user id from the eval sample> LIMIT=20
```

Expected: `signals: [:taste_profile, :collaborative]` and at least one `because you loved …` reason on the page.

- [ ] **Step 7: Write the record**

`docs/data-quality/recommendations-collaborative-2026-10-09.md`, in the style of `recommendations-2026-10-08.md`: what was measured (counts from the export, the two hold-out names), the trainer sweep table (λ, floor, items, rows, hit@10, recall@50, seconds, peak GB), the two harness tables verbatim, a "Verdict against the bar" section going through each condition of spec 2 §8.2 with the numbers, and "What to try next" (the §8.3 experiments). State plainly if a condition is not met.

If the 100+ segment does not improve beyond noise: set `collaborative: false` in `config/initializers/recommendations.rb` with a comment pointing at the record, and say so in the record and in the feature doc.

- [ ] **Step 8: Document**

In `docs/features/recommendations.md`:

- New section `## Collaborative signal` after "Fusion, re-ranking, explanations": what a positive is (the one definition in two places), the three legs and the store, the two tables and the version swap, what the signal does per request (the SQL in words, the ids filter, `because_of` only for a loved book), the local loop in five commands (export → train → load → eval → show), and the production shape in one paragraph pointing at spec 2 §4.4 and increment 2.
- "Harness": add `recommendations:export` and `recommendations:load` with their variables, the `cf` column, and that `VARIANTS="collaborative=false"` is the taste-only comparison; explain why the export's hold-out exists.
- "Knobs": add `collaborative`, `collaborative_min_rating`, `collaborative_overfetch`, `because_of_rating`, and a line listing the Python flags with their defaults.
- "Known gaps": replace the stub line with the measured result (one sentence and a link to the record); fix the spec 1 §8.3 line "`because_of`… never produced today".

In `docs/launch-todo.md` §2, after item 10, add:

```markdown
11. **The collaborative-filtering model (repeating).** After every `data_migration:all` pass:
    `Recommendations::ExportInteractionsJob.perform_async("books")` from a console (or wait for the
    02:30 run), let the home server's `recommender-train` timer run (04:00; or
    `systemctl start recommender-train` on the `ol` VM), then confirm
    `Recommendations::LoadModelJob` loaded it (`RecommendationModel.active_for(:books)`), and that
    `bin/rails recommendations:show USER_ID=…` lists `collaborative`. One-time setup first:
    the private R2 bucket and its token, `RECOMMENDATIONS_R2_*` in the production secrets,
    `RECOMMENDER_R2_*` + `HC_RECOMMENDER` in `secrets/home-server.env`, the healthchecks.io check
    `recommender-train` (period 1 day, grace 2 days), then `deployment/home-server/provision`.
    `docs/features/recommendations.md`, "Collaborative signal".
```

- [ ] **Step 9: Full gate and commit**

```bash
cd web-app && bin/rails test && bundle exec standardrb && CI=1 bin/rails zeitwerk:check
cd ../data-sources && uv run pytest -q && uv run ruff check . && uv run ruff format --check .
```

Expected: green, no new warnings. Then:

```bash
git add docs/data-quality/recommendations-collaborative-2026-10-09.md docs/features/recommendations.md docs/launch-todo.md web-app/config/initializers/recommendations.rb
git commit -m "Measure the collaborative signal against the bar and document it"
```

---

## Self-review notes

- Spec coverage: §3 export → Tasks 2, 4; §4.1–4.3 trainer → Tasks 8–10; §4.4 deployment → increment 2 (not this plan); §4.5 tests → Tasks 8–10; §5 tables and load → Task 5; §6 signal → Tasks 6, 7; §7 knobs → Task 2 (Rails) and Task 10 (Python flags); §8 measurement → Tasks 3, 7 (coverage column), 11; §9 failure modes → tested in Tasks 4, 5, 7, 10; §10 rollout → Task 11 (launch-todo); §11 docs → Tasks 10, 11.
- Naming: `RecommendationModel` / `RecommendationItemNeighbor` replace the spec's `Recommendations::Model` / `ItemNeighbor` (AGENTS.md: shared models stay global). `Interaction#trainable?` takes `min_rating:` (the struct holds no config).
- The hold-out model is loaded as `active` in development during measurement; Task 11 Step 6 replaces it with a full model.
