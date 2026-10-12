require "test_helper"

module Services
  module Books
    module WorldCat
      class BackfillTest < ActiveSupport::TestCase
        class FakeClient
          attr_reader :calls, :looked_up

          def initialize(map, fail_times: 0, error: ::Books::WorldCat::Exceptions::ServerError.new("boom", 500))
            @map = map
            @fail_times = fail_times
            @error = error
            @calls = 0
            @looked_up = []
          end

          def lookup(isbns)
            @calls += 1
            @looked_up.concat(isbns)
            raise @error if (@fail_times -= 1) >= 0

            isbns.to_h { |i| [i, @map.fetch(i, [])] }
          end
        end

        def record(oclc, genre)
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre)
        end

        setup do
          @map = ::Books::WorldCat::GenreMap.new("genres" => ["Fiction"], "terms" => {"Fiction" => {"verdict" => "genre", "genre" => "Fiction"}})
          @war = books_books(:war_and_peace)       # fixture ISBN 9780140447934
          @crime = books_books(:crime_and_punishment)
          ::Identifier.create!(identifiable: @crime, identifier_type: :books_work_isbn13, value: "9780140449136")
          @responses = {"9780140447934" => [record(1, "Fiction"), record(2, "Fiction")], "9780140449136" => [record(3, "Fiction")]}
          @sleeps = []
        end

        def run_backfill(client, **opts)
          Backfill.call(limit: nil, run_id: "run-1", client: client, map: @map, sleeper: ->(s) { @sleeps << s }, **opts)
        end

        test "links categories for every book with an ISBN and reports counts" do
          result = run_backfill(FakeClient.new(@responses))
          assert result.success?
          assert_equal [2, 2, 2, false], result.data.values_at(:processed, :matched, :genres_linked, :stopped)
          assert_equal 0, result.data[:type_conflicts]
          assert_includes @war.reload.categories.pluck(:name), "Fiction"
          assert_includes @crime.reload.categories.pluck(:name), "Fiction"
        end

        test "a limit walks that many books in id order" do
          result = run_backfill(FakeClient.new(@responses), limit: 1)
          assert_equal 1, result.data[:processed]
          assert_includes @war.reload.categories.pluck(:name), "Fiction"
          assert_not_includes @crime.reload.categories.pluck(:name), "Fiction"
        end

        test "a failing batch is retried with backoff and then the run stops" do
          client = FakeClient.new(@responses, fail_times: 2)
          result = run_backfill(client)
          assert_equal [15, 30], @sleeps
          assert result.success?
          assert_equal 2, result.data[:matched]
        end

        test "test_an_open_circuit_stops_the_run_without_skipping_books" do
          client = FakeClient.new(@responses, fail_times: 99, error: ::Books::WorldCat::Exceptions::CircuitOpenError.new("open"))
          result = run_backfill(client, batch_size: 1)
          assert_not result.success?
          assert_equal [15, 30, 60, 120, 240, 300], @sleeps
          assert result.data[:stopped]
          assert_match(/open/, result.data[:error])
          assert_equal 0, result.data[:processed]
          assert_not_includes @war.reload.categories.pluck(:name), "Fiction"
          assert_not_includes @crime.reload.categories.pluck(:name), "Fiction"
        end

        test "a later batch that trips leaves earlier batches' links in place" do
          client = FakeClient.new(@responses, error: ::Books::WorldCat::Exceptions::CircuitOpenError.new("open"))
          client.define_singleton_method(:lookup) do |isbns|
            raise @error if @calls >= 1

            super(isbns)
          end
          result = run_backfill(client, batch_size: 1)
          assert_not result.success?
          assert result.data[:stopped]
          assert_equal 1, result.data[:processed]
          assert_includes @war.reload.categories.pluck(:name), "Fiction"
          assert_not_includes @crime.reload.categories.pluck(:name), "Fiction"
        end

        test "an empty genre map refuses to run and takes no lock" do
          client = FakeClient.new(@responses)
          result = Backfill.call(limit: nil, run_id: "r", client: client, map: ::Books::WorldCat::GenreMap.new({}), sleeper: ->(_) {})
          assert_not result.success?
          assert_match(/no terms/, result.errors.first)
          assert_equal 0, client.calls
        end

        test "unresolved subjects are tallied across the run" do
          map = ::Books::WorldCat::GenreMap.new("genres" => [], "terms" => {"Magic" => {"verdict" => "subject", "subject" => "Sorcery"}})
          responses = {"9780140447934" => [record(1, "Magic")], "9780140449136" => [record(3, "Magic")]}
          result = Backfill.call(limit: nil, run_id: "r", client: FakeClient.new(responses), map: map, sleeper: ->(_) {})
          assert_equal({"Sorcery" => 2}, result.data[:subjects_unresolved])
        end

        test "a book carrying a valid and an invalid ISBN is looked up with the valid one only" do
          ::Identifier.create!(identifiable: @war, identifier_type: :books_work_isbn13, value: "9780140447935") # bad check digit
          client = FakeClient.new(@responses)
          result = run_backfill(client)
          assert result.success?
          assert_equal ["9780140447934", "9780140449136"], client.looked_up.sort
          assert_equal 2, result.data[:matched]
        end

        test "a second run while one holds the lock exits at once" do
          # Advisory locks are re-entrant within one session, and the test pool hands
          # every checkout the same shared connection, so the holder is a separate
          # PG session opened from the same connection settings.
          other = PG.connect(::ActiveRecord::Base.connection.raw_connection.conninfo_hash.compact)
          assert_equal "t", other.exec("SELECT pg_try_advisory_lock(#{Backfill::LOCK_KEY})").getvalue(0, 0)
          result = run_backfill(FakeClient.new(@responses))
          assert_not result.success?
          assert_match(/already running/, result.errors.first)
        ensure
          if other
            other.exec("SELECT pg_advisory_unlock(#{Backfill::LOCK_KEY})")
            other.close
          end
        end
      end
    end
  end
end
