# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class CreateNextYearConfigurationTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @main = ranking_configurations(:books_global)
        @year_2025 = ranking_configurations(:books_year_2025)
      end

      def run_action(config)
        CreateNextYearConfiguration.call(user: @user, models: [config])
      end

      test "name and message" do
        assert_equal "Create Next Year's Configuration", CreateNextYearConfiguration.name
        assert_not_empty CreateNextYearConfiguration.message
      end

      test "visible only on the show view" do
        assert CreateNextYearConfiguration.visible?(view: :show)
        assert_not CreateNextYearConfiguration.visible?(view: :index)
        assert_not CreateNextYearConfiguration.visible?({})
      end

      test "errors on multiple models" do
        result = CreateNextYearConfiguration.call(user: @user, models: [@main, @year_2025])
        assert result.error?
      end

      test "errors on a domain that does not support year rollups" do
        result = run_action(ranking_configurations(:books_authors_global))
        assert result.error?
        assert_match(/does not support year rollups/, result.message)
      end

      test "creates the year after the latest year configuration" do
        result = run_action(@main)

        assert result.success?, result.message
        created = result.data[:ranking_configuration]
        assert_equal 2026, created.year
        assert_equal "The Best Books of 2026", created.name
        assert_instance_of ::Books::RankingConfiguration, created
      end

      test "uses the current year when the domain has no year configuration" do
        @year_2025.destroy!

        created = run_action(@main).data[:ranking_configuration]

        assert_equal Date.current.year, created.year
      end

      test "copies tuned settings from the previous year, not from main" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal @year_2025.exponent, created.exponent
        assert_equal @year_2025.bonus_pool_percentage, created.bonus_pool_percentage
        assert_not_equal @main.bonus_pool_percentage, created.bonus_pool_percentage
      end

      test "forces the date penalty off and clears its bounds" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal false, created.apply_list_dates_penalty
        assert_nil created.max_list_dates_penalty_age
        assert_nil created.max_list_dates_penalty_percentage
      end

      # The first-year case is where this bites: cloning from main would inherit
      # apply_list_dates_penalty true and penalise 2026 books for being on 2026 lists.
      test "forces the date penalty off when cloning from main" do
        @year_2025.destroy!

        created = run_action(@main).data[:ranking_configuration]

        assert_equal true, @main.apply_list_dates_penalty
        assert_equal false, created.apply_list_dates_penalty
      end

      test "creates a non-primary, unpublished, global configuration" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal false, created.primary
        assert_equal true, created.global
        assert_equal false, created.archived
        assert_nil created.published_at
        assert_nil created.inherited_from_id
        assert_nil created.primary_mapped_list_id
        assert_nil created.secondary_mapped_list_id
      end

      test "defaults the cutoffs to 100 and 400 when the source has none" do
        @year_2025.destroy!

        created = run_action(@main).data[:ranking_configuration]

        assert_equal 100, created.primary_mapped_list_cutoff_limit
        assert_equal 400, created.secondary_mapped_list_cutoff_limit
      end

      test "copies cutoffs from the previous year when set" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal @year_2025.primary_mapped_list_cutoff_limit,
          created.primary_mapped_list_cutoff_limit
        assert_equal @year_2025.secondary_mapped_list_cutoff_limit,
          created.secondary_mapped_list_cutoff_limit
      end

      test "excludes every list_time_scope penalty" do
        time_penalty = penalties(:books_one_year_penalty)
        ::PenaltyApplication.create!(penalty: time_penalty, ranking_configuration: @main, value: 50)

        created = run_action(@main).data[:ranking_configuration]

        assert_not_includes created.penalties, time_penalty
      end

      test "excludes a num_years_covered penalty whatever its category" do
        uncategorized = ::Global::Penalty.create!(
          name: "Uncategorized years", dynamic_type: :num_years_covered, category: nil
        )
        ::PenaltyApplication.create!(penalty: uncategorized, ranking_configuration: @main, value: 30)

        created = run_action(@main).data[:ranking_configuration]

        assert_not_includes created.penalties, uncategorized
      end

      # NOTE: the brief's version of this test reused the `cross_media_penalty`
      # fixture, but that penalty is already applied to books_global (fixture
      # `cross_media_penalty_app`, value 15) and PenaltyApplication enforces
      # uniqueness per (penalty, ranking_configuration) -- reapplying it to
      # @main here would raise. Use a fresh penalty instead.
      test "adds penalties main applies that the previous year lacks" do
        gap = ::Global::Penalty.create!(name: "Gap penalty #{SecureRandom.hex(4)}", category: :voter_expertise)
        ::PenaltyApplication.create!(penalty: gap, ranking_configuration: @main, value: 25)

        created = run_action(@main).data[:ranking_configuration]

        assert_equal 25, created.penalty_applications.find_by(penalty: gap).value
      end

      # See note above -- same reason for using a fresh penalty here.
      test "the previous year's tuned value wins over main's" do
        shared = ::Global::Penalty.create!(name: "Shared penalty #{SecureRandom.hex(4)}", category: :voter_expertise)
        ::PenaltyApplication.create!(penalty: shared, ranking_configuration: @main, value: 60)
        ::PenaltyApplication.create!(penalty: shared, ranking_configuration: @year_2025, value: 70)

        created = run_action(@main).data[:ranking_configuration]

        assert_equal 70, created.penalty_applications.find_by(penalty: shared).value
      end

      test "reports what it copied, added and skipped" do
        result = run_action(@main)

        assert_kind_of Integer, result.data[:copied]
        assert_kind_of Integer, result.data[:added]
        assert_kind_of Integer, result.data[:skipped]
        assert_match(/2026/, result.message)
      end
    end
  end
end
