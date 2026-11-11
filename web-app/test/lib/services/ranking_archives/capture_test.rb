# frozen_string_literal: true

require "test_helper"

module Services
  module RankingArchives
    class CaptureTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
        @first = books_books(:war_and_peace)
        @second = books_books(:crime_and_punishment)
        @third = books_books(:cannery_row)
      end

      def rank!(item, rank, score, config: @config)
        ::RankedItem.create!(ranking_configuration: config, item: item, rank: rank, score: score)
      end

      test "captures every ranked item in rank order with its rank and score" do
        rank!(@second, 2, 90)
        rank!(@first, 1, 100)
        rank!(@third, nil, 50)

        result = Capture.call(config: @config, name: "Snapshot")

        assert result.success?, result.errors.inspect
        archive = result.data
        assert archive.persisted?
        assert_equal [@first.id, @second.id], archive.item_ids
        assert_equal [1, 2], archive.positions
        assert_equal [100, 90], archive.scores.map(&:to_i)
        assert_equal @config.id, archive.ranking_configuration_id
        assert_nil archive.period
        assert_instance_of ::Books::RankingArchive, archive
      end

      test "ties keep both items, ordered by item id" do
        rank!(@second, 1, 100)
        rank!(@first, 1, 100)

        archive = Capture.call(config: @config, name: "Snapshot").data

        assert_equal [@first.id, @second.id].sort, archive.item_ids
        assert_equal [1, 1], archive.positions
      end

      test "stores a nil score as zero" do
        rank!(@first, 1, nil)

        archive = Capture.call(config: @config, name: "Snapshot").data

        assert_equal [BigDecimal(0)], archive.reload.scores
      end

      test "items of another item_type are ignored" do
        rank!(@first, 1, 100)
        ::RankedItem.insert_all!([{ranking_configuration_id: @config.id, item_type: "Books::Author", item_id: @first.id, rank: 2, score: 80, created_at: Time.current, updated_at: Time.current}])

        archive = Capture.call(config: @config, name: "Snapshot").data

        assert_equal [@first.id], archive.item_ids
      end

      test "sets the period when given" do
        rank!(@first, 1, 100)

        archive = Capture.call(config: @config, name: "Snapshot", period: Date.new(2026, 10, 1)).data

        assert_equal Date.new(2026, 10, 1), archive.period
      end

      test "refuses a configuration with no ranked items and writes nothing" do
        assert_no_difference -> { ::RankingArchive.count } do
          result = Capture.call(config: @config, name: "Snapshot")

          refute result.success?
          assert_equal [Capture::EMPTY], result.errors
        end
      end

      test "refuses a configuration whose domain has no archive class" do
        config = ranking_configurations(:music_albums_global)

        result = Capture.call(config: config, name: "Snapshot")

        refute result.success?
        assert_equal [Capture::UNSUPPORTED], result.errors
      end

      test "refuses a user-owned configuration" do
        config = ranking_configurations(:books_user)
        rank!(@first, 1, 100, config: config)

        assert_no_difference -> { ::RankingArchive.count } do
          result = Capture.call(config: config, name: "Snapshot")

          refute result.success?
          assert_equal [Capture::NOT_GLOBAL], result.errors
        end
      end

      test "a second capture for the same period fails with ALREADY_ARCHIVED" do
        rank!(@first, 1, 100)
        period = Date.new(2026, 10, 1)
        assert Capture.call(config: @config, name: "October", period: period).success?

        assert_no_difference -> { ::RankingArchive.count } do
          result = Capture.call(config: @config, name: "October again", period: period)

          refute result.success?
          assert_equal [Capture::ALREADY_ARCHIVED], result.errors
        end
      end

      test "a slug collision is not reported as already archived" do
        rank!(@first, 1, 100)
        slug_error = ActiveRecord::RecordNotUnique.new('PG::UniqueViolation: duplicate key value violates unique constraint "index_ranking_archives_on_type_and_slug"')
        ::Books::RankingArchive.any_instance.stubs(:save).raises(slug_error)

        result = Capture.call(config: @config, name: "Snapshot")

        refute result.success?
        assert_equal [slug_error.message], result.errors
      end

      test "returns the record's validation messages when it is invalid" do
        rank!(@first, 1, 100)

        result = Capture.call(config: @config, name: "", period: Date.new(2026, 10, 1))

        refute result.success?
        assert_includes result.errors, "Name can't be blank"
      end

      test "does not change the configuration or request a refresh" do
        rank!(@first, 1, 100)
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

        assert_no_changes -> { @config.reload.attributes } do
          Capture.call(config: @config, name: "Snapshot")
        end
      end
    end
  end
end
