# Coalesced Ranking Recalculation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A burst of merges (or any other ranking trigger) produces one recalculation per ranking configuration, never hundreds, and never two at once.

**Architecture:** Every trigger asks `Services::RankingConfigurations::RequestRefresh` for a refresh. The service claims the configuration row with one conditional UPDATE (`idle`/`failed` → `queued`), so every request after the first is refused until the run starts. `RankingConfigurations::RefreshJob` runs every configuration, global or member-owned: it reweighs, then ranks, then for the books primary only requests the authors refresh and the search reindex. `CalculateRankingsJob` becomes a one-release forwarding shim.

**Tech Stack:** Rails 8, Sidekiq 8.1 (`perform_in`, `set(queue:)`), Minitest 6 + Mocha, fixtures.

**Spec:** `docs/superpowers/specs/2026-10-10-coalesced-ranking-recalculation-design.md`

## Global Constraints

- All Rails commands run from `web-app/` inside this worktree: `/home/shane/dev/the-greatest/.claude/worktrees/coalesce-ranking-recalcs/web-app`. Docs live at the worktree root, in `docs/`.
- Automatic triggers (mergers, verdict application, provisional revert) use `delay: 5.minutes`. Deliberate requests (admin Refresh Rankings, member Refresh, dynamic lists, the author cron, the primary → authors follow-up, the shim) use the default `delay: 0`.
- Global configurations (`user_id` nil) run on the `default` queue. User-owned configurations keep `RefreshJob`'s own `low` queue.
- `RankingConfiguration::REFRESH_STALE_AFTER` stays `1.hour`. A books primary run takes 5-10 minutes.
- A change that lands while a run is `running` is **not** guaranteed its own run. Do not add rerun-if-changed-mid-run machinery (the spec rules it out).
- Root-anchor constants inside namespaces: `::Services::RankingConfigurations::RequestRefresh`, `::Books::Authors::RankingConfiguration`, `::RankingConfiguration`.
- Primary follow-ups are gated on `config.type == "Books::RankingConfiguration" && config.default_primary?`. Note that `Books::Authors::RankingConfiguration` subclasses `::RankingConfiguration`, not `Books::RankingConfiguration`.
- Minitest 6: `assert_equal nil, x` is a hard failure, so use `assert_nil`.
- Lint with `bundle exec standardrb` (never `bin/rubocop`). Do not run brakeman.
- No Playwright test: no user-facing page or flow is new.
- Commit on branch `worktree-coalesce-ranking-recalcs`. Never commit to `main`. Never push without asking.
- Sidekiq runs `:inline` in tests (`test/test_helper.rb`). Use `Sidekiq::Testing.fake! { ... }` plus `RankingConfigurations::RefreshJob.clear` whenever a test counts or inspects enqueued jobs.
- A global configuration enqueues through `RefreshJob.set(queue: "default")`, a `Sidekiq::Job::Setter`. So `RefreshJob.expects(:perform_async)` only observes **member** configurations. For a global one, count `RefreshJob.jobs` under `Sidekiq::Testing.fake!`.
- Merger post-commit steps rescue everything into `merger.stats[:post_commit_error]`, which includes Mocha expectation failures. Every merger test that sets an expectation on a post-commit step must also `assert_nil merger.stats[:post_commit_error]`, or a violated expectation passes silently.

## Review Focus

1. **The queue is backed up for longer than the stale window.** A request reclaims the stale row and puts a second `RefreshJob` behind the first. Expected: only one of them calculates. *Pinned in Task 2: "a run whose row is not queued is skipped".*
2. **`call_for_ids` is given nil, `[]`, duplicates or a deleted configuration's id.** Expected: no error, one job per real configuration. *Pinned in Task 1.*
3. **There is no authors primary configuration** (e.g. a domain switched on without one) when the books primary finishes. Expected: the books run still ends `idle`, and the reindex still goes out. *Pinned in Task 2.*
4. **Redis is unreachable while a merge commits.** Expected: the merge succeeds and the configuration row ends `failed` (claimable), not stuck `queued`. *Pinned in Task 3.*
5. **An admin clicks Refresh Rankings while a merge-triggered run is already queued.** Expected: a warning that a run is already queued or running, not a false "queued" success. *Pinned in Task 5.*

---

### Task 1: `RequestRefresh` takes a delay, routes queues, and accepts ids

**Files:**
- Modify: `web-app/app/lib/services/ranking_configurations/request_refresh.rb`
- Test: `web-app/test/lib/services/ranking_configurations/request_refresh_test.rb`

**Interfaces:**
- Produces:
  - `Services::RankingConfigurations::RequestRefresh.call(config:, delay: 0)` → `Result(success?:, data: {ranking_configuration:, reason:}, errors:)`. `reason` is `nil`, `:already_running` or `:enqueue_failed`.
  - `Services::RankingConfigurations::RequestRefresh.call_for_ids(ids, delay: 0)` → `Array<Result>`, one per configuration found. `ids` may be nil, empty or contain duplicates and missing ids.
  - `Services::RankingConfigurations::RequestRefresh::Result` (unchanged struct).

- [ ] **Step 1: Write the failing tests**

Append these tests inside `class RequestRefreshTest` in `web-app/test/lib/services/ranking_configurations/request_refresh_test.rb`, after the last existing test:

```ruby
      test "a global configuration runs on the default queue, immediately" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert RequestRefresh.call(config: global).success?

          job = ::RankingConfigurations::RefreshJob.jobs.sole
          assert_equal "default", job["queue"]
          assert_equal [global.id], job["args"]
          assert_nil job["at"]
        end
      end

      test "a member's configuration keeps the job's own low queue" do
        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert RequestRefresh.call(config: @config).success?

          assert_equal "low", ::RankingConfigurations::RefreshJob.jobs.sole["queue"]
        end
      end

      test "a delay schedules the run that far ahead and the row is queued now" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert RequestRefresh.call(config: global, delay: 5.minutes).success?

          job = ::RankingConfigurations::RefreshJob.jobs.sole
          assert_in_delta 5.minutes.from_now.to_f, job["at"], 2
          assert global.reload.refresh_queued?
        end
      end

      test "a burst of delayed requests for one configuration queues one run" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          results = 5.times.map { RequestRefresh.call(config: ::RankingConfiguration.find(global.id), delay: 5.minutes) }

          assert_equal [true, false, false, false, false], results.map(&:success?)
          assert_equal 1, ::RankingConfigurations::RefreshJob.jobs.size
        end
      end

      test "call_for_ids claims each configuration once, skipping nil, duplicate and missing ids" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          results = RequestRefresh.call_for_ids([global.id, @config.id, global.id, nil, -1], delay: 5.minutes)

          assert_equal 2, results.size
          assert results.all?(&:success?)
          assert_equal [global.id, @config.id].sort,
            ::RankingConfigurations::RefreshJob.jobs.map { |job| job["args"].first }.sort
        end
      end

      test "call_for_ids with nothing to refresh does nothing" do
        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert_equal [], RequestRefresh.call_for_ids(nil)
          assert_equal [], RequestRefresh.call_for_ids([])
          assert_empty ::RankingConfigurations::RefreshJob.jobs
        end
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/ranking_configurations/request_refresh_test.rb`
Expected: the new tests FAIL. The global configuration lands on `low`, `delay:` is an unknown keyword (ArgumentError), and `call_for_ids` is undefined (NoMethodError). The six existing tests still pass.

- [ ] **Step 3: Implement**

Replace the whole of `web-app/app/lib/services/ranking_configurations/request_refresh.rb` with:

```ruby
# frozen_string_literal: true

# Claims a configuration's refresh lock and enqueues the job. Every ranking
# recalculation in the app comes through here: a member's Refresh, the admin
# Refresh Rankings action, record merges, Goodreads verdicts, dynamic lists
# and the author cron.
#
# The claim is one conditional UPDATE: two simultaneous callers serialize on
# the row lock and the loser re-evaluates the WHERE against the winner's
# committed value, so at most one caller ever sees a changed row. That refusal
# is what coalesces a burst -- 500 merges touching the primary queue one run,
# not 500. A change that lands while the run is in progress waits for the next
# trigger; that is accepted (see the 2026-10-10 coalesced ranking
# recalculation spec). The stale clause reclaims a row wedged by a worker killed
# mid-run, which no rescue in the job can catch.
#
# The claim commits before the enqueue, so an unreachable Redis would
# otherwise leave the row "queued" -- and every request refused -- for the
# whole stale window. An enqueue failure therefore releases the claim into
# `failed` with the reason, which the manage page shows and the next request
# can retry.
#
# `delay` lets automatic triggers collect a burst before the run starts.
# Global configurations go on `default`; members' keep RefreshJob's own `low`,
# which strict queue priority keeps behind everything site-wide.
#
# Model constants are root-anchored: Services::RankingConfiguration is an
# existing module, so a bare RankingConfiguration here would resolve to it.
module Services
  module RankingConfigurations
    class RequestRefresh
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      ALREADY_RUNNING = "A refresh is already running for this ranking."
      ENQUEUE_FAILED = "The refresh could not be queued. Try again in a moment."

      def self.call(config:, delay: 0)
        new(config: config, delay: delay).call
      end

      # The mergers, the Goodreads verdicts and the repair-verdicts controller
      # hold ids, not records. Each configuration gets its own claim.
      def self.call_for_ids(ids, delay: 0)
        ::RankingConfiguration.where(id: Array(ids).compact.uniq).map { |config| call(config: config, delay: delay) }
      end

      def initialize(config:, delay: 0)
        @config = config
        @delay = delay
      end

      def call
        return failure(:already_running, ALREADY_RUNNING) unless claim

        begin
          enqueue
        rescue => error
          release(error)
          return failure(:enqueue_failed, ENQUEUE_FAILED)
        end

        Result.new(success?: true, data: {ranking_configuration: config, reason: nil}, errors: [])
      end

      private

      attr_reader :config, :delay

      def statuses
        ::RankingConfiguration.refresh_statuses
      end

      def claim
        claimed = ::RankingConfiguration.where(id: config.id)
          .where("refresh_status IN (:free) OR refresh_requested_at < :stale",
            free: [statuses[:idle], statuses[:failed]],
            stale: ::RankingConfiguration::REFRESH_STALE_AFTER.ago)
          .update_all(refresh_status: statuses[:queued], refresh_requested_at: Time.current, last_refresh_error: nil)
        return false unless claimed == 1

        config.reload
        true
      end

      def enqueue
        job = config.user_owned? ? ::RankingConfigurations::RefreshJob : ::RankingConfigurations::RefreshJob.set(queue: "default")
        delay.to_i.positive? ? job.perform_in(delay, config.id) : job.perform_async(config.id)
      end

      def release(error)
        Rails.logger.error "[Services::RankingConfigurations::RequestRefresh] configuration #{config.id}: #{error.class}: #{error.message}"
        ::RankingConfiguration.where(id: config.id).update_all(
          refresh_status: statuses[:failed],
          last_refresh_error: "Could not queue the refresh: #{error.message}".truncate(500)
        )
        config.reload
      end

      def failure(reason, message)
        Result.new(success?: false, data: {ranking_configuration: config, reason: reason}, errors: [message])
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/ranking_configurations/request_refresh_test.rb test/lib/services/ranking_configurations/create_test.rb test/controllers/my/ranking_configurations_controller_test.rb`
Expected: PASS. The member paths still call `RefreshJob.perform_async` directly, so the existing member tests are unaffected.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/ranking_configurations/request_refresh.rb test/lib/services/ranking_configurations/request_refresh_test.rb
git add app/lib/services/ranking_configurations/request_refresh.rb test/lib/services/ranking_configurations/request_refresh_test.rb
git commit -m "RequestRefresh takes a delay, routes global configurations to default, and accepts ids

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `RefreshJob` runs every configuration, starts only from `queued`, and owns the primary follow-ups

**Files:**
- Modify: `web-app/app/sidekiq/ranking_configurations/refresh_job.rb`
- Test: `web-app/test/sidekiq/ranking_configurations/refresh_job_test.rb`

**Interfaces:**
- Consumes: `::Services::RankingConfigurations::RequestRefresh.call(config:)` (Task 1).
- Produces: `RankingConfigurations::RefreshJob#perform(ranking_configuration_id)`. It only calculates when the row is `queued`. For the books default primary only, it requests the authors primary refresh and enqueues `Books::ReindexRankedFieldsJob` on success.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/sidekiq/ranking_configurations/refresh_job_test.rb`:

(a) Add a helper below `setup` (inside the class):

```ruby
    def queue!(config)
      config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:queued], refresh_requested_at: Time.current)
      config
    end

    def stub_clean_run
      Rankings::BulkWeightCalculator.any_instance.stubs(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.stubs(:calculate_rankings).returns(@success)
    end
```

(b) Replace the existing test `"does not enqueue the search reindex or author rankings"` with:

```ruby
    test "a member's ranking requests neither the author rankings nor the search reindex" do
      stub_clean_run
      Books::ReindexRankedFieldsJob.expects(:perform_async).never
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_idle?
    end
```

(c) Append these tests at the end of the class:

```ruby
    test "a run whose row is not queued is skipped, so a second job never calculates alongside the first" do
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running])
      Rankings::BulkWeightCalculator.any_instance.expects(:call).never
      RankingConfiguration.any_instance.expects(:calculate_rankings).never

      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_running?, "the run that holds the row is left alone"
    end

    test "an idle row is skipped too" do
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      Rankings::BulkWeightCalculator.any_instance.expects(:call).never

      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_idle?
    end

    test "weights are calculated before rankings" do
      order = sequence("weights then rankings")
      Rankings::BulkWeightCalculator.any_instance.expects(:call).in_sequence(order).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).in_sequence(order).returns(@success)

      RefreshJob.new.perform(@config.id)
    end

    test "the books primary requests the author rankings and the search reindex after it lands" do
      primary = queue!(ranking_configurations(:books_global))
      stub_clean_run
      ::Services::RankingConfigurations::RequestRefresh.expects(:call)
        .with(config: ranking_configurations(:books_authors_global)).once
      Books::ReindexRankedFieldsJob.expects(:perform_async).once

      RefreshJob.new.perform(primary.id)

      assert primary.reload.refresh_idle?
    end

    test "a global configuration other than the books primary requests no follow-ups" do
      [:books_authors_global, :music_albums_global].each do |name|
        config = queue!(ranking_configurations(name))
        stub_clean_run
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
        Books::ReindexRankedFieldsJob.expects(:perform_async).never

        RefreshJob.new.perform(config.id)

        assert config.reload.refresh_idle?, "#{name} should end idle"
      end
    end

    test "with no authors primary the books primary still finishes and reindexes" do
      ranking_configurations(:books_authors_global).update_columns(primary: false)
      primary = queue!(ranking_configurations(:books_global))
      stub_clean_run
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
      Books::ReindexRankedFieldsJob.expects(:perform_async).once

      RefreshJob.new.perform(primary.id)

      assert primary.reload.refresh_idle?
    end

    test "a failure requesting the follow-ups does not fail a run that landed" do
      primary = queue!(ranking_configurations(:books_global))
      stub_clean_run
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).raises(StandardError, "redis hiccup")
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: primary, rerun_if_generating: true).once

      RefreshJob.new.perform(primary.id)

      primary.reload
      assert primary.refresh_idle?
      assert_nil primary.last_refresh_error
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/sidekiq/ranking_configurations/refresh_job_test.rb`
Expected: FAIL. Both skip tests calculate anyway. The primary follow-up tests see no `RequestRefresh.call` / reindex. The no-authors-primary test sees no reindex.

- [ ] **Step 3: Implement**

Replace the whole of `web-app/app/sidekiq/ranking_configurations/refresh_job.rb` with:

```ruby
# frozen_string_literal: true

# Recalculates one ranking configuration -- global or member-owned -- as one
# unit of work: list weights first, then item rankings, so the ranking never
# reads weights a separate job has not finished yet. Always queued through
# Services::RankingConfigurations::RequestRefresh, whose claim on the row is
# what keeps a burst of triggers down to one run.
#
# Status lives on the configuration row (RankingConfiguration#refresh_status),
# which is why this never retries -- the next request is the retry, and a
# Sidekiq retry would rerun invisibly while the row still said "failed".
#
# A run starts only from `queued`. A stale claim can put a second job in the
# queue while the first is still waiting or working, and that second job must
# not calculate alongside it.
#
# needs_refresh is cleared when the run STARTS, not when it ends: an edit made
# while this job is running (Save, AddLists, remove) sets it back to true, and
# the run in flight is computing from data that no longer matches, so the
# successful-end update must never touch it -- otherwise it would stomp the
# edit's true back to false and the page would claim "Up to date" for
# rankings computed from stale, pre-edit data. A failure sets it back to true
# unconditionally, since whatever it was computing didn't land either way.
#
# Only the books default primary feeds the author rankings and the ranked
# fields in the search index, so only it requests them. A member's ranking or
# a year rollup finishing must trigger neither.
module RankingConfigurations
  class RefreshJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(ranking_configuration_id)
      config = ::RankingConfiguration.find_by(id: ranking_configuration_id)
      return if config.nil? # deleted while queued -- not a failure
      return unless start(config)

      weights = Rankings::BulkWeightCalculator.new(config).call
      if weights[:errors].any?
        first = weights[:errors].first
        raise "Weight calculation failed for #{weights[:errors].size} list(s): #{first[:list_name]}: #{first[:error]}"
      end

      result = config.calculate_rankings
      raise "Ranking calculation failed: #{result.errors.join(", ")}" unless result.success?

      config.update_columns(
        refresh_status: ::RankingConfiguration.refresh_statuses[:idle],
        last_refreshed_at: Time.current,
        last_refresh_error: nil
      )

      request_primary_follow_ups(config)
      request_csv_regenerate(config)
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{ranking_configuration_id}: #{e.message}"
      ::RankingConfiguration.where(id: ranking_configuration_id).update_all(
        refresh_status: ::RankingConfiguration.refresh_statuses[:failed],
        needs_refresh: true,
        last_refresh_error: e.message.truncate(500)
      )
    end

    private

    # queued -> running in one conditional UPDATE; false means another job
    # already holds this run, or nothing asked for one.
    def start(config)
      statuses = ::RankingConfiguration.refresh_statuses
      ::RankingConfiguration.where(id: config.id, refresh_status: statuses[:queued])
        .update_all(refresh_status: statuses[:running], needs_refresh: false) == 1
    end

    # Their own rescue, like the CSV request: the ranking already landed, and a
    # hiccup here must not flip the row to "failed".
    def request_primary_follow_ups(config)
      return unless config.type == "Books::RankingConfiguration" && config.default_primary?

      authors = ::Books::Authors::RankingConfiguration.default_primary
      ::Services::RankingConfigurations::RequestRefresh.call(config: authors) if authors
      ::Books::ReindexRankedFieldsJob.perform_async
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{config.id}: follow-ups not requested: #{e.message}"
    end

    # The CSV is a side effect of the refresh, not part of it: a failure here
    # must not flip a configuration whose rankings did land to "failed". Logged
    # rather than raised -- retry: false means a raise would only be logged
    # anyway, and the next request or member download re-claims the row.
    # rerun_if_generating: a run already in flight plucked its ids before
    # these ranks landed, so it must go again when it finishes.
    def request_csv_regenerate(config)
      ::Services::CsvExports::RequestGenerate.call(ranking_configuration: config, rerun_if_generating: true)
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{config.id}: CSV regenerate not requested: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/sidekiq/ranking_configurations/refresh_job_test.rb test/lib/services/ranking_configurations/ test/controllers/my/ranking_configurations_controller_test.rb`
Expected: PASS, every test including the pre-existing ones (their `setup` already puts `books_user` in `queued`).

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/sidekiq/ranking_configurations/refresh_job.rb test/sidekiq/ranking_configurations/refresh_job_test.rb
git add app/sidekiq/ranking_configurations/refresh_job.rb test/sidekiq/ranking_configurations/refresh_job_test.rb
git commit -m "RefreshJob starts only from queued and requests the books primary's follow-ups

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Every merger requests a coalesced refresh

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb` (`schedule_ranking_recalculation`, ~line 605-614, plus the comment on `regenerate_user_favorites_list` ~line 616-621)
- Modify: `web-app/app/lib/games/game/merger.rb` (`schedule_ranking_recalculation`, ~line 390-395, plus the favorites comment below it)
- Modify: `web-app/app/lib/music/album/merger.rb` (~line 227-232, plus the favorites comment)
- Modify: `web-app/app/lib/music/song/merger.rb` (~line 249-254, plus the favorites comment)
- Modify: `web-app/app/lib/music/artist/merger.rb` (~line 253-258)
- Modify: `web-app/app/lib/books/author/merger.rb` (`schedule_ranking_recalculation`, ~line 455-462)
- Test: `web-app/test/lib/books/book/merger_test.rb`, `web-app/test/lib/games/game/merger_test.rb`, `web-app/test/lib/music/album/merger_test.rb`, `web-app/test/lib/music/song/merger_test.rb`, `web-app/test/lib/music/artist/merger_test.rb`, `web-app/test/lib/books/author/merger_test.rb`, `web-app/test/controllers/admin/books/authors_controller_test.rb`, `web-app/test/lib/actions/admin/books/merge_author_test.rb`

**Interfaces:**
- Consumes: `::Services::RankingConfigurations::RequestRefresh.call_for_ids(ids, delay:)` and `.call(config:, delay:)` (Task 1). `RefreshJob` (Task 2).
- Produces: nothing new. `Books::Book::Merger#affected_ranking_configurations` and `defer_rankings:` are unchanged.

- [ ] **Step 1: Write the failing tests**

**`web-app/test/lib/books/book/merger_test.rb`:**

Replace the test `"schedules ranking recalculation for every affected configuration"` with:

```ruby
      test "requests a delayed refresh of every affected configuration" do
        config = ranking_configurations(:books_global)
        RankedItem.create!(item: @source, ranking_configuration: config, rank: 5)
        ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([config.id], delay: 5.minutes).once
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error],
          "a violated Mocha expectation in a post-commit step is swallowed into this key"
      end
```

In `"defer_rankings leaves the ranking and favorites jobs to the caller, and names the configurations"`, replace these two lines:

```ruby
        BulkCalculateWeightsJob.expects(:perform_async).never
        CalculateRankingsJob.expects(:perform_in).never
```

with:

```ruby
        ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).never
```

In `"collects the source's ranking configurations before the destroy cascade"`, replace:

```ruby
        BulkCalculateWeightsJob.expects(:perform_async).with(config.id).once
        CalculateRankingsJob.stubs(:perform_in)
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        ::Books::Book::Merger.call(source: @source, target: @target)
```

with:

```ruby
        ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([config.id], delay: 5.minutes).once
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        merger.call

        assert_nil merger.stats[:post_commit_error]
```

Then add these two tests directly after `"collects the source's ranking configurations before the destroy cascade"`:

```ruby
      # The bug this whole change exists for: a session of merges in the admin
      # queued one full recalculation per merge per configuration.
      test "a burst of merges sharing configurations queues one refresh per configuration" do
        global = ranking_configurations(:books_global)
        member = ranking_configurations(:books_user)
        pairs = 3.times.map do |i|
          source = ::Books::Book.create!(title: "Burst Source #{i}")
          target = ::Books::Book.create!(title: "Burst Target #{i}")
          [global, member].each { |config| RankedItem.create!(item: source, ranking_configuration: config, rank: 900 + i) }
          [source, target]
        end

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          pairs.each do |source, target|
            merger = ::Books::Book::Merger.new(source: source, target: target)
            assert merger.call.success?
            assert_nil merger.stats[:post_commit_error]
          end

          assert_equal({global.id => 1, member.id => 1},
            ::RankingConfigurations::RefreshJob.jobs.map { |job| job["args"].first }.tally)
        end
      end

      test "a merge still commits when Redis is unreachable, and the configuration stays claimable" do
        config = ranking_configurations(:books_global)
        RankedItem.create!(item: @source, ranking_configuration: config, rank: 5)
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        Sidekiq::Job::Setter.any_instance.stubs(:perform_in).raises(RedisClient::CannotConnectError, "redis is down")

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_not ::Books::Book.exists?(@source.id)
        config.reload
        assert config.refresh_failed?
        assert config.refresh_claimable?
      end
```

**`web-app/test/lib/games/game/merger_test.rb`, `web-app/test/lib/music/album/merger_test.rb`, `web-app/test/lib/music/song/merger_test.rb`, `web-app/test/lib/music/artist/merger_test.rb`.** In each file, apply these exact replacements (`grep -n "CalculateRankingsJob\|BulkCalculateWeightsJob"` finds every site):

| Existing lines | Replace with |
|---|---|
| `BulkCalculateWeightsJob.expects(:perform_async).with(config.id)` + `CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)` | `::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([config.id], delay: 5.minutes).once` |
| the four lines expecting `config1`/`config2` jobs (album, song) | `::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([config1.id, config2.id], delay: 5.minutes).once` |
| `BulkCalculateWeightsJob.expects(:perform_async).never` + `CalculateRankingsJob.expects(:perform_in).never` | `::Services::RankingConfigurations::RequestRefresh.expects(:call).never` (the merger still calls `call_for_ids([])`; what must not happen is a claim) |
| `CalculateRankingsJob.stubs(:perform_in)` (album line ~117, song line ~382) | `::Services::RankingConfigurations::RequestRefresh.stubs(:call_for_ids)` |

In **every** test whose expectations you replaced, `.never` ones included, change the bare `Music::Album::Merger.call(...)` (and the Song, Artist and Game equivalents) to the instance form and assert the swallowed-error key, as in the book test above:

```ruby
        merger = Music::Album::Merger.new(source: @source_album, target: @target_album)
        merger.call

        assert_nil merger.stats[:post_commit_error]
```

All five mergers expose `stats` and rescue post-commit errors into `stats[:post_commit_error]`. A violated `.never` raises at call time and is swallowed there. Without this assertion a `.never` test cannot fail. An unmet `.once` is still caught at teardown.

Also rewrite the comments in these test files that name `CalculateRankingsJob`:
- "before CalculateRankingsJob reads the list" becomes "before RankingConfigurations::RefreshJob reads the list".
- "queues a BulkCalculateWeightsJob of its own -- which would land on these expectations" stays as it is. That job is still queued by `GenerateUserFavorites` for a new list. It is no longer an expectation in these tests, so delete the trailing clause "-- which would land on these expectations".

**`web-app/test/lib/books/author/merger_test.rb`:**
- In `setup`, replace `::Books::CalculateAuthorRankingsJob.stubs(:perform_async)` with `::Services::RankingConfigurations::RequestRefresh.stubs(:call)`. Update its comment so it says the merger requests an authors-primary refresh unconditionally, which runs inline.
- In `"defer_rankings leaves the author ranking recalculation to the caller"`, replace `::Books::CalculateAuthorRankingsJob.expects(:perform_async).never` with `::Services::RankingConfigurations::RequestRefresh.expects(:call).never`.
- Replace the test `"schedules the author ranking recalculation"` with:

```ruby
      test "requests a delayed refresh of the authors primary" do
        ::Services::RankingConfigurations::RequestRefresh.expects(:call)
          .with(config: ranking_configurations(:books_authors_global), delay: 5.minutes).once

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error],
          "a violated Mocha expectation in a post-commit step is swallowed into this key"
      end

      test "requests nothing when there is no authors primary" do
        ranking_configurations(:books_authors_global).update_columns(primary: false)
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

        merger = ::Books::Author::Merger.new(source: @source, target: @target)

        assert merger.call.success?
        assert_nil merger.stats[:post_commit_error]
      end
```

**`web-app/test/controllers/admin/books/authors_controller_test.rb`** (4 sites) and **`web-app/test/lib/actions/admin/books/merge_author_test.rb`** (1 site): replace every `::Books::CalculateAuthorRankingsJob.stubs(:perform_async)` with `::Services::RankingConfigurations::RequestRefresh.stubs(:call)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb test/lib/games/game/merger_test.rb test/lib/music/album/merger_test.rb test/lib/music/song/merger_test.rb test/lib/music/artist/merger_test.rb`
Expected: FAIL. The `call_for_ids` / `call` expectations are not met (the mergers still enqueue the old jobs). The burst test counts 0 `RefreshJob`s, because the old `CalculateRankingsJob` was queued instead.

- [ ] **Step 3: Implement**

In **each** of `app/lib/books/book/merger.rb`, `app/lib/games/game/merger.rb`, `app/lib/music/album/merger.rb`, `app/lib/music/song/merger.rb`, `app/lib/music/artist/merger.rb`, replace the method body and the comment directly above it:

```ruby
      # Post-commit: perform_in writes to Redis, which a rollback cannot undo.
      # RequestRefresh claims each configuration, so a burst of merges sharing a
      # configuration queues one run for it, not one per merge; the delay lets
      # the burst collect. The run reweighs before it ranks.
      def schedule_ranking_recalculation
        ::Services::RankingConfigurations::RequestRefresh.call_for_ids(@affected_ranking_configurations, delay: 5.minutes)
      end
```

For `app/lib/books/book/merger.rb` only, append this line to that comment:

```ruby
      # Author rankings follow: RefreshJob requests them when the books primary lands.
```

In the favorites-regeneration comment in the book, game, album and song mergers, change "before CalculateRankingsJob would otherwise read that short list" (and "before schedule_ranking_recalculation's CalculateRankingsJob would otherwise read") to "before schedule_ranking_recalculation's RefreshJob would otherwise read". Leave the logic alone.

In `app/lib/books/author/merger.rb`, replace `schedule_ranking_recalculation` and its comment with:

```ruby
      # Author rankings derive from book rankings rather than from lists, so
      # there are no per-configuration ids to collect: the one configuration to
      # refresh is the authors primary. RequestRefresh claims it, so a burst of
      # author merges queues one run. Post-commit: perform_in writes to Redis,
      # which a rollback cannot undo.
      def schedule_ranking_recalculation
        authors = ::Books::Authors::RankingConfiguration.default_primary
        ::Services::RankingConfigurations::RequestRefresh.call(config: authors, delay: 5.minutes) if authors
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb test/lib/games/game/merger_test.rb test/lib/music/album/merger_test.rb test/lib/music/song/merger_test.rb test/lib/music/artist/merger_test.rb test/controllers/admin/books/authors_controller_test.rb test/lib/actions/admin/books/merge_author_test.rb test/lib/actions/admin/`
Expected: PASS.

Then confirm the mergers no longer name the old jobs:
Run: `grep -rn "CalculateRankingsJob\|BulkCalculateWeightsJob\|CalculateAuthorRankingsJob" app/lib/*/*/merger.rb`
Expected: no output.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/books app/lib/games app/lib/music test/lib/books test/lib/games test/lib/music test/controllers/admin/books/authors_controller_test.rb test/lib/actions/admin/books/merge_author_test.rb
git add app/lib/books/book/merger.rb app/lib/books/author/merger.rb app/lib/games/game/merger.rb app/lib/music/album/merger.rb app/lib/music/song/merger.rb app/lib/music/artist/merger.rb test/lib/books test/lib/games test/lib/music test/controllers/admin/books/authors_controller_test.rb test/lib/actions/admin/books/merge_author_test.rb
git commit -m "Mergers request a coalesced, delayed refresh instead of queuing jobs per merge

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Goodreads verdicts, provisional revert and dynamic lists request refreshes

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_replay/apply_verdicts.rb` (`queue_follow_ups`, ~line 58-71)
- Modify: `web-app/app/controllers/admin/books/repair_verdicts_controller.rb` (`revert_provisional`, ~line 92-96)
- Modify: `web-app/app/lib/services/lists/generate_dynamic_lists.rb` (`recalculate_primary` and its comment, ~line 297-319)
- Modify: `web-app/lib/tasks/dynamic_lists.rake` (~line 103-107)
- Test: `web-app/test/lib/services/books/goodreads_replay/apply_verdicts_test.rb`, `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb`, `web-app/test/lib/services/lists/generate_dynamic_lists_test.rb`, `web-app/test/lib/tasks/dynamic_lists_rake_test.rb`

**Interfaces:**
- Consumes: `RequestRefresh.call_for_ids(ids, delay:)` and `RequestRefresh.call(config:, delay: 0)` (Task 1).
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

**`apply_verdicts_test.rb`:**
- In `"applies approved verdicts kind by kind: ..."`, replace `::CalculateRankingsJob.expects(:perform_async).with(42).once` with:

```ruby
          ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([42], delay: 5.minutes).once
```

- In `"queues each follow-up once per run, however many merges asked for it"`, replace these lines:

```ruby
          ::BulkCalculateWeightsJob.expects(:perform_async).with(1).once
          ::BulkCalculateWeightsJob.expects(:perform_async).with(2).once
          ::CalculateRankingsJob.expects(:perform_in).with(5.minutes, 1).once
          ::CalculateRankingsJob.expects(:perform_in).with(5.minutes, 2).once
          ::CalculateRankingsJob.expects(:perform_async).with(3).once
          ::GenerateUserFavoritesListsJob.expects(:perform_async).with("Books::UserList").once
          ::Books::CalculateAuthorRankingsJob.expects(:perform_async).once
```

with:

```ruby
          ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([1, 2, 3], delay: 5.minutes).once
          ::GenerateUserFavoritesListsJob.expects(:perform_async).with("Books::UserList").once
          ::Services::RankingConfigurations::RequestRefresh.expects(:call)
            .with(config: ranking_configurations(:books_authors_global), delay: 5.minutes).once
```

- In `"an author merge chain applies in id order, ..."`, replace `::Books::CalculateAuthorRankingsJob.stubs(:perform_async)` with `::Services::RankingConfigurations::RequestRefresh.stubs(:call)`.
- In `"a slug fix-up and a relink on the same book ..."`, replace the two lines `::BulkCalculateWeightsJob.stubs(:perform_async)` and `::CalculateRankingsJob.stubs(:perform_in)` with `::Services::RankingConfigurations::RequestRefresh.stubs(:call_for_ids)`. Update the comment above them from "queues the favorites rebuild and ranking jobs" to "queues the favorites rebuild and a ranking refresh".

**`repair_verdicts_controller_test.rb`**, in `"rejecting an applied mark_provisional reverts it"`: replace `::CalculateRankingsJob.stubs(:perform_async)` with:

```ruby
        ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with(anything, delay: 5.minutes).once
```

**`generate_dynamic_lists_test.rb`:** replace the two tests at the end of the file with:

```ruby
      test "requests a refresh of the primary configuration" do
        rank(@books)
        main = ::Books::RankingConfiguration.default_primary
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).with(config: main).once

        GenerateDynamicLists.call(ranking_configuration: @config)
      end

      test "skips the primary refresh when asked to" do
        rank(@books)
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

        GenerateDynamicLists.call(ranking_configuration: @config, recalculate_primary: false)
      end
```

Then run `grep -n "CalculateRankingsJob" test/lib/services/lists/generate_dynamic_lists_test.rb`. Turn any remaining `CalculateRankingsJob.stubs(:perform_async)` into `::Services::RankingConfigurations::RequestRefresh.stubs(:call)`.

**`dynamic_lists_rake_test.rb`:**
- Replace the ordering test `"regenerate runs each year configuration inline, then queues the single primary refresh, in that order"` (and the paragraph of comment above it, which describes the `call_order` workaround) with:

```ruby
  # A regression that hoists the primary refresh above (or into) the per-year
  # loop would recalculate the primary against stale mapped lists. A Mocha
  # sequence pins the order; two independent `.once` expectations would not.
  #
  # Stubs GenerateDynamicListsJob's instance `perform` (not `perform_async`):
  # the task runs each year's generator inline and synchronously, in the same
  # process, so nothing is ever enqueued for it.
  test "regenerate runs each year configuration inline, then requests the single primary refresh, in that order" do
    @config.update_column(:year, 2025)
    order = sequence("generate then refresh")

    GenerateDynamicListsJob.any_instance.expects(:perform).with(@config.id, false).once.in_sequence(order)
    ::Services::RankingConfigurations::RequestRefresh.expects(:call)
      .with(config: ::Books::RankingConfiguration.default_primary).once.in_sequence(order)

    run_task("dynamic_lists:regenerate", "Books::RankingConfiguration")
  end
```

- Replace the two remaining `CalculateRankingsJob.stubs(:perform_async)` with `::Services::RankingConfigurations::RequestRefresh.stubs(:call)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/books/goodreads_replay/apply_verdicts_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb test/lib/services/lists/generate_dynamic_lists_test.rb test/lib/tasks/dynamic_lists_rake_test.rb`
Expected: FAIL. The `RequestRefresh` expectations are unmet, because the code still enqueues the old jobs.

- [ ] **Step 3: Implement**

**`apply_verdicts.rb`:** replace `queue_follow_ups` and its comment with the following, and add `request_author_rankings` directly below it:

```ruby
        # The merges defer their per-merge requests, so a run of thousands of
        # merges asks for each configuration once. Every refresh reweighs before
        # it ranks, so a configuration a merge touched and one only a provisional
        # flag touched get the same request. Sorted so the request is
        # deterministic.
        def queue_follow_ups
          ::Services::RankingConfigurations::RequestRefresh.call_for_ids((@rankings | @reweigh).sort, delay: 5.minutes)
          ::GenerateUserFavoritesListsJob.perform_async("Books::UserList") if @follow_ups.include?(:user_favorites)
          request_author_rankings if @follow_ups.include?(:author_rankings)
        end

        def request_author_rankings
          authors = ::Books::Authors::RankingConfiguration.default_primary
          ::Services::RankingConfigurations::RequestRefresh.call(config: authors, delay: 5.minutes) if authors
        end
```

Leave `@rankings` / `@reweigh` collection in `apply` unchanged. The handlers still report both keys, and the union is what gets requested.

**`repair_verdicts_controller.rb`**, in `revert_provisional`, replace:

```ruby
    Array(result.data[:ranking_configuration_ids]).each { |id| ::CalculateRankingsJob.perform_async(id) }
```

with:

```ruby
    ::Services::RankingConfigurations::RequestRefresh.call_for_ids(result.data[:ranking_configuration_ids], delay: 5.minutes)
```

**`generate_dynamic_lists.rb`**, in `recalculate_primary`, replace:

```ruby
        ::CalculateRankingsJob.perform_async(main.id) if @recalculate_primary
```

with:

```ruby
        ::Services::RankingConfigurations::RequestRefresh.call(config: main) if @recalculate_primary
```

In the comment above `recalculate_primary`, replace the paragraph starting "The ranking recalculation is safe as perform_async ..." with:

```ruby
      # The refresh request is safe to make now because the lists are fully
      # written and re-weighted by the time it is enqueued. It goes through the
      # same RequestRefresh claim as the Refresh Rankings button, so a run that
      # is already queued absorbs it.
```

**`lib/tasks/dynamic_lists.rake`:** replace

```ruby
      puts "Queueing one ranking refresh for #{main.name.inspect}."
      CalculateRankingsJob.perform_async(main.id)
```

with

```ruby
      puts "Requesting one ranking refresh for #{main.name.inspect}."
      Services::RankingConfigurations::RequestRefresh.call(config: main)
```

Also update the comment in this rake file (~line 72-78) that says "a trailing CalculateRankingsJob" / "before the single CalculateRankingsJob is enqueued". Change those to "a trailing ranking refresh" / "before the single ranking refresh is requested".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/books/goodreads_replay/ test/controllers/admin/books/repair_verdicts_controller_test.rb test/lib/services/lists/generate_dynamic_lists_test.rb test/lib/tasks/dynamic_lists_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/books/goodreads_replay/apply_verdicts.rb app/controllers/admin/books/repair_verdicts_controller.rb app/lib/services/lists/generate_dynamic_lists.rb lib/tasks/dynamic_lists.rake test/lib/services/books/goodreads_replay/apply_verdicts_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb test/lib/services/lists/generate_dynamic_lists_test.rb test/lib/tasks/dynamic_lists_rake_test.rb
git add app/lib/services/books/goodreads_replay/apply_verdicts.rb app/controllers/admin/books/repair_verdicts_controller.rb app/lib/services/lists/generate_dynamic_lists.rb lib/tasks/dynamic_lists.rake test/lib/services/books/goodreads_replay/apply_verdicts_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb test/lib/services/lists/generate_dynamic_lists_test.rb test/lib/tasks/dynamic_lists_rake_test.rb
git commit -m "Verdicts, provisional revert and dynamic lists request refreshes through the claim

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Admin Refresh Rankings, the author cron, and the `CalculateRankingsJob` shim

**Files:**
- Modify: `web-app/app/lib/actions/admin/refresh_rankings.rb`
- Modify: `web-app/app/models/ranking_configuration.rb` (delete `calculate_rankings_async`, ~line 212-214)
- Modify: `web-app/app/sidekiq/books/calculate_author_rankings_job.rb`
- Modify: `web-app/app/sidekiq/calculate_rankings_job.rb` (becomes the shim)
- Test: `web-app/test/lib/actions/admin/music/refresh_rankings_test.rb`
- Test: `web-app/test/controllers/admin/games/ranking_configurations_controller_test.rb`, `web-app/test/controllers/admin/music/albums/ranking_configurations_controller_test.rb`, `web-app/test/controllers/admin/music/artists/ranking_configurations_controller_test.rb`, `web-app/test/controllers/admin/music/songs/ranking_configurations_controller_test.rb`
- Test: `web-app/test/sidekiq/books/calculate_author_rankings_job_test.rb`
- Test: `web-app/test/sidekiq/calculate_rankings_job_test.rb` (rewritten for the shim)

**Interfaces:**
- Consumes: `RequestRefresh.call(config:)` and `RequestRefresh::Result` (Task 1).
- Produces: `Actions::Admin::RefreshRankings#call` → `succeed` when queued, `warn` when a run is already queued or running, `error` when the enqueue failed. `RankingConfiguration#calculate_rankings_async` no longer exists.

- [ ] **Step 1: Write the failing tests**

**`test/lib/actions/admin/music/refresh_rankings_test.rb`:** replace the four tests from `"calls calculate_rankings_async on configuration"` through `"works with different configuration types"` with:

```ruby
        def refresh_result(success:, reason: nil, errors: [])
          ::Services::RankingConfigurations::RequestRefresh::Result.new(
            success?: success, data: {ranking_configuration: @ranking_config, reason: reason}, errors: errors
          )
        end

        test "requests a refresh of the configuration" do
          ::Services::RankingConfigurations::RequestRefresh.expects(:call)
            .with(config: @ranking_config).returns(refresh_result(success: true))

          result = RefreshRankings.new(user: @user, models: [@ranking_config]).call

          assert result.success?
          assert_equal "Ranking calculation queued for #{@ranking_config.name}.", result.message
        end

        test "warns instead of claiming success when a run is already queued or running" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
            .returns(refresh_result(success: false, reason: :already_running,
              errors: [::Services::RankingConfigurations::RequestRefresh::ALREADY_RUNNING]))

          result = RefreshRankings.new(user: @user, models: [@ranking_config]).call

          assert result.warning?
          assert_equal "A ranking calculation is already queued or running for #{@ranking_config.name}.", result.message
        end

        test "reports an error when the refresh could not be queued" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
            .returns(refresh_result(success: false, reason: :enqueue_failed,
              errors: [::Services::RankingConfigurations::RequestRefresh::ENQUEUE_FAILED]))

          result = RefreshRankings.new(user: @user, models: [@ranking_config]).call

          assert result.error?
          assert_equal ::Services::RankingConfigurations::RequestRefresh::ENQUEUE_FAILED, result.message
        end

        test "a second click while the first is queued only warns, end to end" do
          Sidekiq::Testing.fake! do
            ::RankingConfigurations::RefreshJob.clear

            assert RefreshRankings.call(user: @user, models: [@ranking_config]).success?
            assert RefreshRankings.call(user: @user, models: [::RankingConfiguration.find(@ranking_config.id)]).warning?
            assert_equal 1, ::RankingConfigurations::RefreshJob.jobs.size
          end
        end
```

**The four admin `ranking_configurations_controller_test.rb` files** (games lines ~340/352/366/378; albums ~319/332/346/358; artists ~310/322/336; songs ~319/332/346/358):
- Replace each `::<Domain>::RankingConfiguration.any_instance.expects(:calculate_rankings_async)` with:

```ruby
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).returns(
          ::Services::RankingConfigurations::RequestRefresh::Result.new(success?: true, data: {}, errors: [])
        )
```

- Replace each `@ranking_configuration.expects(:calculate_rankings_async).never` with `::Services::RankingConfigurations::RequestRefresh.expects(:call).never`. Keep each line's original indentation.

**`test/sidekiq/books/calculate_author_rankings_job_test.rb`:** replace its body with:

```ruby
require "test_helper"

module Books
  class CalculateAuthorRankingsJobTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_authors_global)
    end

    test "requests a refresh of the primary author configuration instead of calculating inline" do
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).with(config: @config).returns(
        ::Services::RankingConfigurations::RequestRefresh::Result.new(success?: true, data: {}, errors: [])
      )
      Books::Authors::RankingConfiguration.any_instance.expects(:calculate_rankings).never

      Books::CalculateAuthorRankingsJob.new.perform
    end

    test "a refresh already queued or running is not an error and queues nothing" do
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running], refresh_requested_at: Time.current)

      # A global configuration enqueues through RefreshJob.set(queue:), not
      # RefreshJob.perform_async, so count the fake queue rather than expect on
      # the class method -- an expectation there could never fire.
      Sidekiq::Testing.fake! do
        ::RankingConfigurations::RefreshJob.clear

        assert_nothing_raised { Books::CalculateAuthorRankingsJob.new.perform }
        assert_empty ::RankingConfigurations::RefreshJob.jobs
      end
    end

    test "raises when there is no primary author configuration" do
      @config.update!(primary: false)

      assert_raises(RuntimeError) { Books::CalculateAuthorRankingsJob.new.perform }
    end
  end
end
```

**`test/sidekiq/calculate_rankings_job_test.rb`:** replace the whole file with:

```ruby
# frozen_string_literal: true

require "test_helper"

# CalculateRankingsJob is a one-release shim (see the class). Delete this file
# with it.
class CalculateRankingsJobTest < ActiveSupport::TestCase
  test "forwards to a refresh request instead of calculating" do
    config = ranking_configurations(:music_albums_global)
    ::Services::RankingConfigurations::RequestRefresh.expects(:call).with(config: config).once
    RankingConfiguration.any_instance.expects(:calculate_rankings).never

    CalculateRankingsJob.new.perform(config.id)
  end

  test "a configuration deleted since the job was queued is a silent no-op" do
    ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

    assert_nothing_raised { CalculateRankingsJob.new.perform(-1) }
  end

  test "a backlog of old jobs for one configuration collapses into one refresh" do
    config = ranking_configurations(:books_global)

    Sidekiq::Testing.fake! do
      ::RankingConfigurations::RefreshJob.clear

      50.times { CalculateRankingsJob.new.perform(config.id) }

      assert_equal 1, ::RankingConfigurations::RefreshJob.jobs.size
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/actions/admin/music/refresh_rankings_test.rb test/controllers/admin/games/ranking_configurations_controller_test.rb test/controllers/admin/music/albums/ranking_configurations_controller_test.rb test/controllers/admin/music/artists/ranking_configurations_controller_test.rb test/controllers/admin/music/songs/ranking_configurations_controller_test.rb test/sidekiq/books/calculate_author_rankings_job_test.rb test/sidekiq/calculate_rankings_job_test.rb`
Expected: FAIL. The action still calls `calculate_rankings_async`, the author job still calculates inline, and the shim still calculates.

- [ ] **Step 3: Implement**

**`app/lib/actions/admin/refresh_rankings.rb`:** replace `call` with:

```ruby
      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        result = Services::RankingConfigurations::RequestRefresh.call(config: config)
        return succeed("Ranking calculation queued for #{config.name}.") if result.success?
        return warn("A ranking calculation is already queued or running for #{config.name}.") if result.data[:reason] == :already_running

        error(result.errors.first)
      end
```

**`app/models/ranking_configuration.rb`:** delete the method (and nothing else):

```ruby
  def calculate_rankings_async
    CalculateRankingsJob.perform_async(id)
  end
```

Confirm nothing else calls it: `grep -rn "calculate_rankings_async" app lib test` should print nothing.

**`app/sidekiq/books/calculate_author_rankings_job.rb`:** replace the whole file with:

```ruby
# The nightly safety net for The Greatest Authors (config/schedule.yml, 04:00),
# and what an operator runs by hand. It claims the authors primary through
# RequestRefresh rather than calculating inline, so it can never run alongside
# a refresh that a books recalculation or an author merge already queued.
class Books::CalculateAuthorRankingsJob
  include Sidekiq::Job

  def perform
    config = Books::Authors::RankingConfiguration.default_primary

    if config.nil?
      Rails.logger.error "No primary Books::Authors::RankingConfiguration; author rankings not calculated"
      raise "No primary Books::Authors::RankingConfiguration"
    end

    result = ::Services::RankingConfigurations::RequestRefresh.call(config: config)
    return if result.success?

    Rails.logger.info "Author rankings refresh not requested for configuration #{config.id}: #{result.errors.join(", ")}"
  end
end
```

**`app/sidekiq/calculate_rankings_job.rb`:** replace the whole file with:

```ruby
# Transitional -- delete this class and test/sidekiq/calculate_rankings_job_test.rb
# in the release after the one that introduced it. Every recalculation now goes
# through Services::RankingConfigurations::RequestRefresh and
# RankingConfigurations::RefreshJob. This only exists so the jobs already in
# Redis when that shipped -- thousands of them after a merge session -- collapse
# into one claimed refresh per configuration instead of dying with NameError.
class CalculateRankingsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id)
    config = RankingConfiguration.find_by(id: ranking_configuration_id)
    return if config.nil?

    Services::RankingConfigurations::RequestRefresh.call(config: config)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command as Step 2. Expected: PASS.

Then: `cd web-app && grep -rn "CalculateRankingsJob" app lib config | grep -v "^app/sidekiq/calculate_rankings_job.rb"`
Expected: no output.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/actions/admin/refresh_rankings.rb app/models/ranking_configuration.rb app/sidekiq/books/calculate_author_rankings_job.rb app/sidekiq/calculate_rankings_job.rb test/lib/actions/admin/music/refresh_rankings_test.rb test/controllers/admin test/sidekiq
git add app/lib/actions/admin/refresh_rankings.rb app/models/ranking_configuration.rb app/sidekiq/books/calculate_author_rankings_job.rb app/sidekiq/calculate_rankings_job.rb test/lib/actions/admin/music/refresh_rankings_test.rb test/controllers/admin/games/ranking_configurations_controller_test.rb test/controllers/admin/music/albums/ranking_configurations_controller_test.rb test/controllers/admin/music/artists/ranking_configurations_controller_test.rb test/controllers/admin/music/songs/ranking_configurations_controller_test.rb test/sidekiq/books/calculate_author_rankings_job_test.rb test/sidekiq/calculate_rankings_job_test.rb
git commit -m "Admin refresh, the author cron and CalculateRankingsJob go through the claim

CalculateRankingsJob is now a one-release shim so jobs already in Redis at
deploy collapse into one refresh per configuration. Delete it next release.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Docs, launch todo, and full verification

**Files:**
- Modify: `docs/features/rankings.md` (the "Background Processing" section, ~line 164-178, and "Background Calculation", ~line 199-207)
- Modify: `docs/features/user-ranking-configurations.md` (~line 79-85 and ~line 88-92)
- Modify: `docs/features/record-merge.md` (~line 142-149, ~line 250-252, ~line 303-306)
- Modify: `docs/features/books-provisional-records.md` (~line 47-50)
- Modify: `docs/features/csv-exports.md` (~line 30 and ~line 93)
- Modify: `docs/launch-todo.md` (§1 step 2, ~line 18-22)

All doc paths are at the worktree root (`/home/shane/dev/the-greatest/.claude/worktrees/coalesce-ranking-recalcs/docs/`), not under `web-app/`.

- [ ] **Step 1: `docs/features/rankings.md`**

Replace the whole `### CalculateRankingsJob` subsection (heading through its "Error Handling" bullets) with:

````markdown
### Recalculation is coalesced

Every ranking recalculation, for every domain, global or member-owned, is requested through
`Services::RankingConfigurations::RequestRefresh` and run by `RankingConfigurations::RefreshJob`:

```ruby
Services::RankingConfigurations::RequestRefresh.call(config: config)                       # now
Services::RankingConfigurations::RequestRefresh.call_for_ids(ids, delay: 5.minutes)        # after a burst
```

- **The claim is the coalescing.** One conditional UPDATE moves the row from `idle`/`failed` to
  `queued`. While it is `queued` or `running`, every further request is refused, so 500 merges
  touching the primary queue one run. A row stuck in progress for longer than
  `RankingConfiguration::REFRESH_STALE_AFTER` (1 hour) can be claimed again.
- **Delays:** automatic triggers (record merges, Goodreads verdicts, the provisional revert) wait
  5 minutes so a burst collects. Buttons, dynamic lists and the 04:00 author cron run at once.
- **Queues:** global configurations go on `default`, members' on `low`.
- **One job, in order:** `RefreshJob` starts only from `queued`, reweighs, ranks, and then, for
  the books default primary only, requests the authors primary refresh and enqueues
  `Books::ReindexRankedFieldsJob`. Every run also requests a CSV regenerate.
- **Accepted trade-off:** a change that lands while a run is `running` is not guaranteed its own
  run; it waits for the next trigger. Triggers are frequent and public pages are served from the
  Cloudflare cache.
- `CalculateRankingsJob` remains for one release as a shim that forwards to `RequestRefresh`, so
  jobs already in Redis at deploy collapse instead of dying. It is then deleted.
````

Replace the "Background Calculation" example's code with:

```ruby
# Queue a ranking refresh (refused if one is already queued or running)
config = RankingConfiguration.find(1)
Services::RankingConfigurations::RequestRefresh.call(config: config)
```

- [ ] **Step 2: The other feature docs**

- **`user-ranking-configurations.md`:**
  - Replace the bullet that says the admin per-row "Refresh Rankings" action "calls `calculate_rankings_async` directly -- it does not go through `Services::RankingConfigurations::RequestRefresh`..." with: the admin "Refresh Rankings" action goes through `Services::RankingConfigurations::RequestRefresh` like the member's button, so it respects the same claim and updates `refresh_status`. Bulk admin actions (`BulkCalculateWeights`) still run against every row of the type.
  - In "Search indexing", replace "`CalculateRankingsJob` only triggers author rankings and the reindex for the primary" with "`RankingConfigurations::RefreshJob` only requests author rankings and the reindex for the books default primary".
- **`record-merge.md`:**
  - Rewrite the bullet "**Ranking recalculation is one argument-less job.**" so that it says list-based mergers request `RequestRefresh.call_for_ids(affected ids, delay: 5.minutes)`, and the author merger requests a refresh of `Books::Authors::RankingConfiguration.default_primary` with the same delay. Keep the point that there is no `collect_affected_ranking_configurations` step for authors. Its last parenthetical becomes "a book merge gets author recalculation because `RefreshJob` requests it when the books primary lands".
  - In the "Book merge queues no author reindex fan-out" paragraph, make the same change to its last sentence.
  - In the testing paragraph, replace "`Books::CalculateAuthorRankingsJob.perform_async` is stubbed in `setup`" with "`Services::RankingConfigurations::RequestRefresh.call` is stubbed in `setup`".
- **`books-provisional-records.md`:** replace "one `CalculateRankingsJob` per configuration that ranked the book, plus the default one, whose job cascades to the author rankings" with "one `RequestRefresh` per configuration that ranked the book, plus the default one, whose refresh requests the author rankings when it lands".
- **`csv-exports.md`:** replace `CalculateRankingsJob` / `RankingConfigurations::RefreshJob` with just `RankingConfigurations::RefreshJob` in both places, and adjust the verb agreement ("calls", "its own rescue").

- [ ] **Step 3: `docs/launch-todo.md`**

In §1 step 2, replace "Then recalculate the books list weights and rankings. Author rankings follow from the book rankings: `Books::CalculateAuthorRankingsJob` runs on the 04:00 UTC cron, or by hand." with:

```markdown
   Then use the admin **Refresh Rankings** action on the books primary. That one run reweighs,
   ranks and requests the author rankings when it lands. The 04:00 UTC author cron is the safety
   net. **The release after this one ships deletes the transitional `CalculateRankingsJob` shim**
   (see `docs/superpowers/specs/2026-10-10-coalesced-ranking-recalculation-design.md` §4).
```

- [ ] **Step 4: Full verification**

Run each command and read the output. Do not claim success on a partial run.

```bash
cd web-app && bin/rails test
```
Expected: 0 failures, 0 errors, and no new warning lines beyond the two known upstream sources (`weighted_list_rank`'s `puts`, npm/yarn during `test:prepare`).

```bash
cd web-app && bundle exec standardrb
```
Expected: no offenses.

```bash
cd web-app && CI=1 bin/rails zeitwerk:check
```
Expected: "All is good!"

```bash
cd web-app && grep -rn "CalculateRankingsJob\|calculate_rankings_async" app lib config test | grep -v "^app/sidekiq/calculate_rankings_job.rb\|^test/sidekiq/calculate_rankings_job_test.rb"
```
Expected: no output, apart from comments that describe the shim's history, if any were kept deliberately.

```bash
cd web-app && grep -rn "CalculateAuthorRankingsJob" app lib config | grep -v "^app/sidekiq/books/calculate_author_rankings_job.rb"
```
Expected: only `config/schedule.yml`.

- [ ] **Step 5: Commit**

```bash
git add ../docs/features/rankings.md ../docs/features/user-ranking-configurations.md ../docs/features/record-merge.md ../docs/features/books-provisional-records.md ../docs/features/csv-exports.md ../docs/launch-todo.md
git commit -m "Docs: ranking recalculation is coalesced through RequestRefresh

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

After this task, tell Shane that the branch is unpushed, and remind him that the `CalculateRankingsJob` shim gets deleted in the release after this one ships.
