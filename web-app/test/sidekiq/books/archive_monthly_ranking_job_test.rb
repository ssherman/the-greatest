require "test_helper"

module Books
  class ArchiveMonthlyRankingJobTest < ActiveSupport::TestCase
    setup do
      @primary = ranking_configurations(:books_global)
      # The fixtures give the primary no ranked items; the January 2027 archive
      # fixture already holds that month.
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @primary, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @primary, rank: 2, score: 90)
    end

    test "retries only twice, since the daily cron heals a missed run" do
      assert_equal 2, Books::ArchiveMonthlyRankingJob.sidekiq_options["retry"]
    end

    test "creates the month's archive from the primary, named for the month" do
      travel_to Time.utc(2027, 2, 1, 5, 15) do
        assert_difference -> { Books::RankingArchive.count }, 1 do
          Books::ArchiveMonthlyRankingJob.new.perform
        end
      end

      archive = Books::RankingArchive.order(:id).last
      assert_equal ["February 2027", Date.new(2027, 2, 1), @primary.id],
        [archive.name, archive.period, archive.ranking_configuration_id]
    end

    test "does nothing when the month already has an archive" do
      travel_to Time.utc(2027, 2, 1, 5, 15) do
        Books::ArchiveMonthlyRankingJob.new.perform

        assert_no_difference -> { Books::RankingArchive.count } do
          Books::ArchiveMonthlyRankingJob.new.perform
        end
      end
    end

    test "does nothing in a month the fixture archive already covers" do
      travel_to Time.utc(2027, 1, 15, 5, 15) do
        ::Services::RankingArchives::Capture.expects(:call).never

        assert_no_difference -> { Books::RankingArchive.count } do
          Books::ArchiveMonthlyRankingJob.new.perform
        end
      end
    end

    test "a first run mid-month archives that month" do
      travel_to Time.utc(2026, 11, 10, 5, 15) do
        Books::ArchiveMonthlyRankingJob.new.perform
      end

      archive = Books::RankingArchive.find_by!(period: Date.new(2026, 11, 1))
      assert_equal "November 2026", archive.name
    end

    test "the month is the UTC month" do
      travel_to Time.utc(2027, 2, 28, 23, 59) do
        Books::ArchiveMonthlyRankingJob.new.perform
      end

      assert_equal "February 2027", Books::RankingArchive.order(:id).last.name
    end

    test "an archive from last month does not satisfy this month" do
      assert Books::RankingArchive.exists?(ranking_configuration_id: @primary.id, period: Date.new(2027, 1, 1))

      travel_to Time.utc(2027, 2, 1, 5, 15) do
        assert_difference -> { Books::RankingArchive.where(period: Date.new(2027, 2, 1)).count }, 1 do
          Books::ArchiveMonthlyRankingJob.new.perform
        end
      end
    end

    test "raises and writes nothing when the primary has no ranked items" do
      RankedItem.where(ranking_configuration_id: @primary.id).delete_all

      travel_to Time.utc(2027, 2, 1, 5, 15) do
        assert_no_difference -> { Books::RankingArchive.count } do
          error = assert_raises(RuntimeError) { Books::ArchiveMonthlyRankingJob.new.perform }
          assert_includes error.message, ::Services::RankingArchives::Capture::EMPTY
        end
      end
    end

    test "raises when there is no primary books configuration" do
      @primary.update_columns(primary: false)

      assert_raises(RuntimeError) { Books::ArchiveMonthlyRankingJob.new.perform }
    end

    test "still creates the archive when a manual archive holds the month's slug" do
      Books::RankingArchive.create!(name: "February 2027", captured_at: Time.current, item_ids: [1], positions: [1], scores: [1])

      travel_to(Time.utc(2027, 2, 1, 5, 15)) { Books::ArchiveMonthlyRankingJob.new.perform }

      assert_equal "february-2027-2", Books::RankingArchive.find_by!(period: Date.new(2027, 2, 1)).slug
    end

    test "returns quietly when another run created the month's archive in the meantime" do
      travel_to Time.utc(2027, 2, 1, 5, 15) do
        ::Services::RankingArchives::Capture.stubs(:call).with do
          Books::RankingArchive.create!(ranking_configuration_id: @primary.id, period: Date.new(2027, 2, 1), name: "February 2027",
            captured_at: Time.current, item_ids: [1], positions: [1], scores: [1])
          true
        end.returns(::Services::RankingArchives::Capture::Result.new(success?: false, data: nil, errors: ["x"]))

        assert_nothing_raised { Books::ArchiveMonthlyRankingJob.new.perform }
      end
    end

    test "never requests a refresh" do
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

      travel_to(Time.utc(2027, 2, 1, 5, 15)) { Books::ArchiveMonthlyRankingJob.new.perform }
    end
  end
end
