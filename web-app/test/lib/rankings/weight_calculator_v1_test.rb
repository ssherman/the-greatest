# frozen_string_literal: true

require "test_helper"

module Rankings
  class WeightCalculatorV1Test < ActiveSupport::TestCase
    def setup
      @books_ranked_list = ranked_lists(:books_ranked_list)
      @books_list = @books_ranked_list.list
      @books_config = @books_ranked_list.ranking_configuration
      @calculator = WeightCalculatorV1.new(@books_ranked_list)
    end

    # Test basic weight calculation without penalties
    test "calculates base weight when no penalties applied" do
      # Create a fresh music albums config to avoid fixture interference
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Clean Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create a list with no penalties
      clean_list = Music::Albums::List.create!(
        name: "Clean Test List",
        status: :approved,
        high_quality_source: false
      )

      clean_ranked_list = RankedList.create!(
        list: clean_list,
        ranking_configuration: test_config
      )

      calculator = WeightCalculatorV1.new(clean_ranked_list)
      weight = calculator.call

      # Should be base weight (100) minus nothing, but respecting minimum
      expected_weight = [100, test_config.min_list_weight].max
      assert_equal expected_weight, weight
      assert_equal weight, clean_ranked_list.reload.weight
    end

    # Test penalty calculation from existing fixtures
    test "applies penalties from list penalty associations" do
      # The books_list fixture has several penalties through list_penalties
      @books_ranked_list.weight
      new_weight = @calculator.call

      # Should be different from original (fixtures show weight: 10, but we'll recalculate)
      refute_nil new_weight
      assert_kind_of Integer, new_weight

      # Weight should be saved to the ranked_list
      assert_equal new_weight, @books_ranked_list.reload.weight
    end

    # Test high quality source bonus
    test "applies quality source bonus reducing penalties" do
      # Create fresh music albums config to avoid fixture interference
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Quality Bonus Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create two identical lists, one high quality, one not
      regular_list = Music::Albums::List.create!(
        name: "Regular List",
        status: :approved,
        high_quality_source: false
      )

      high_quality_list = Music::Albums::List.create!(
        name: "High Quality List",
        status: :approved,
        high_quality_source: true
      )

      # Create a penalty to apply to both
      test_penalty = Music::Penalty.create!(
        type: "Music::Penalty",
        name: "Test Penalty"
      )

      PenaltyApplication.create!(
        penalty: test_penalty,
        ranking_configuration: test_config,
        value: 30
      )

      # Apply penalty to both lists
      ListPenalty.create!(list: regular_list, penalty: test_penalty)
      ListPenalty.create!(list: high_quality_list, penalty: test_penalty)

      regular_ranked_list = RankedList.create!(
        list: regular_list,
        ranking_configuration: test_config
      )

      high_quality_ranked_list = RankedList.create!(
        list: high_quality_list,
        ranking_configuration: test_config
      )

      regular_weight = WeightCalculatorV1.new(regular_ranked_list).call
      high_quality_weight = WeightCalculatorV1.new(high_quality_ranked_list).call

      # High quality list should have higher weight (less penalty applied)
      assert_operator high_quality_weight, :>, regular_weight
    end

    # Test minimum weight floor
    test "enforces minimum weight floor" do
      # Create a list with extreme penalties that would go below minimum
      extreme_penalty_list = Books::List.create!(
        name: "Extreme Penalty List",
        status: :approved,
        high_quality_source: false
      )

      extreme_penalty = Books::Penalty.create!(
        type: "Books::Penalty",
        name: "Extreme Penalty"
      )

      PenaltyApplication.create!(
        penalty: extreme_penalty,
        ranking_configuration: @books_config,
        value: 99  # 99% penalty should floor at minimum
      )

      ListPenalty.create!(list: extreme_penalty_list, penalty: extreme_penalty)

      extreme_ranked_list = RankedList.create!(
        list: extreme_penalty_list,
        ranking_configuration: @books_config
      )

      weight = WeightCalculatorV1.new(extreme_ranked_list).call

      # Should not go below minimum weight
      assert_equal @books_config.min_list_weight, weight
    end

    # Test voter count penalty calculation
    test "calculates voter count penalty with power curve" do
      # Create fresh music albums ranking configuration to avoid fixture interference
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Voter Penalty Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create music albums lists with different voter counts
      few_voters_list = Music::Albums::List.create!(
        name: "Few Voters List",
        status: :approved,
        number_of_voters: 2  # Below median
      )

      many_voters_list = Music::Albums::List.create!(
        name: "Many Voters List",
        status: :approved,
        number_of_voters: 100  # Well above median
      )

      one_voter_list = Music::Albums::List.create!(
        name: "One Voter List",
        status: :approved,
        number_of_voters: 1  # Minimum
      )

      # Create a dynamic voter penalty
      voter_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Low Voter Count Penalty",
        dynamic_type: :number_of_voters
      )

      PenaltyApplication.create!(
        penalty: voter_penalty,
        ranking_configuration: test_config,
        value: 20
      )

      few_voters_ranked = RankedList.create!(list: few_voters_list, ranking_configuration: test_config)
      many_voters_ranked = RankedList.create!(list: many_voters_list, ranking_configuration: test_config)
      one_voter_ranked = RankedList.create!(list: one_voter_list, ranking_configuration: test_config)

      # Check median calculation: [1, 2, 100] -> median = 2
      median = test_config.median_voter_count
      assert_equal 2, median, "Median should be 2 for voters [1, 2, 100]"

      few_voters_weight = WeightCalculatorV1.new(few_voters_ranked).call
      many_voters_weight = WeightCalculatorV1.new(many_voters_ranked).call
      one_voter_weight = WeightCalculatorV1.new(one_voter_ranked).call

      # Many voters (100) should have highest weight (no penalty since > median of 2)
      # Few voters (2) are at the median so get minimal penalty (power curve gives 0)
      # One voter should have maximum penalty
      assert_equal 100, many_voters_weight, "Many voters should get no penalty (weight = 100)"
      assert_equal 100, few_voters_weight, "Few voters at median get no penalty due to power curve (weight = 100)"
      assert_operator one_voter_weight, :<, 100, "One voter should get significant penalty (weight < 100)"

      # The key test: one voter should have significantly lower weight than the others
      assert_operator one_voter_weight, :<, few_voters_weight, "One voter should have lower weight than few voters"
      assert_operator one_voter_weight, :<, many_voters_weight, "One voter should have lower weight than many voters"
    end

    # Test attribute-based penalties
    test "applies penalties based on list attributes" do
      category_specific_list = Books::List.create!(
        name: "Category Specific List",
        status: :approved,
        category_specific: true
      )

      location_specific_list = Books::List.create!(
        name: "Location Specific List",
        status: :approved,
        location_specific: true
      )

      unknown_voters_list = Books::List.create!(
        name: "Unknown Voters List",
        status: :approved,
        voter_names_unknown: true,
        voter_count_unknown: true
      )

      # Create penalties that match the attribute names
      category_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Category Specific Bias",
        dynamic_type: :category_specific
      )

      location_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Location Specific Bias",
        dynamic_type: :location_specific
      )

      unknown_names_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Unknown Voter Names",
        dynamic_type: :voter_names_unknown
      )

      unknown_count_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Unknown Voter Count",
        dynamic_type: :voter_count_unknown
      )

      # Create penalty applications
      [category_penalty, location_penalty, unknown_names_penalty, unknown_count_penalty].each do |penalty|
        PenaltyApplication.create!(
          penalty: penalty,
          ranking_configuration: @books_config,
          value: 15
        )
      end

      # Create clean list for comparison
      clean_list = Books::List.create!(
        name: "Clean List",
        status: :approved,
        category_specific: false,
        location_specific: false,
        voter_names_unknown: false,
        voter_count_unknown: false
      )

      # Create ranked lists
      category_ranked = RankedList.create!(list: category_specific_list, ranking_configuration: @books_config)
      location_ranked = RankedList.create!(list: location_specific_list, ranking_configuration: @books_config)
      unknown_ranked = RankedList.create!(list: unknown_voters_list, ranking_configuration: @books_config)
      clean_ranked = RankedList.create!(list: clean_list, ranking_configuration: @books_config)

      category_weight = WeightCalculatorV1.new(category_ranked).call
      location_weight = WeightCalculatorV1.new(location_ranked).call
      unknown_weight = WeightCalculatorV1.new(unknown_ranked).call
      clean_weight = WeightCalculatorV1.new(clean_ranked).call

      # Lists with issues should have lower weights than clean list
      assert_operator clean_weight, :>, category_weight
      assert_operator clean_weight, :>, location_weight
      assert_operator clean_weight, :>, unknown_weight
    end

    # Test penalty percentage cap at 100%
    test "caps total penalty percentage at 100%" do
      extreme_penalty_list = Books::List.create!(
        name: "Multiple Extreme Penalties List",
        status: :approved
      )

      # Create multiple high-value penalties
      penalties = []
      3.times do |i|
        penalty = Global::Penalty.create!(
          type: "Global::Penalty",
          name: "Extreme Penalty #{i}"
        )

        PenaltyApplication.create!(
          penalty: penalty,
          ranking_configuration: @books_config,
          value: 60  # 3 x 60% = 180%, should be capped at 100%
        )

        ListPenalty.create!(list: extreme_penalty_list, penalty: penalty)
        penalties << penalty
      end

      extreme_ranked = RankedList.create!(list: extreme_penalty_list, ranking_configuration: @books_config)
      weight = WeightCalculatorV1.new(extreme_ranked).call

      # Should floor at minimum weight since 100% penalty would make weight 0
      assert_equal @books_config.min_list_weight, weight
    end

    # Test that both cross-media and media-specific penalties are applied
    test "applies both cross-media and music-specific penalties to music configuration" do
      # Create fresh test data to avoid fixture conflicts
      music_config = Music::Albums::RankingConfiguration.create!(
        name: "Test Music Albums Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Apply both cross-media and music-specific penalties to our test configuration
      cross_media_penalty = penalties(:global_penalty)  # This is a cross-media penalty (Global::Penalty)
      music_penalty = penalties(:music_penalty)         # This is a music-specific penalty (Music::Penalty)

      PenaltyApplication.create!(penalty: cross_media_penalty, ranking_configuration: music_config, value: 15)
      PenaltyApplication.create!(penalty: music_penalty, ranking_configuration: music_config, value: 20)

      # Create a fresh music albums list with penalties
      music_list = Music::Albums::List.create!(
        name: "Test Music Albums List #{SecureRandom.hex(4)}",
        status: :approved,
        high_quality_source: false,
        number_of_voters: 150
      )

      # Associate penalties directly with the list
      ListPenalty.create!(list: music_list, penalty: cross_media_penalty)
      ListPenalty.create!(list: music_list, penalty: music_penalty)

      # Create ranked list
      music_ranked_list = RankedList.create!(
        list: music_list,
        ranking_configuration: music_config
      )

      calculator = WeightCalculatorV1.new(music_ranked_list)

      # Verify the configuration has both cross-media and music-specific penalty applications
      applied_penalties = music_config.penalty_applications.includes(:penalty)
      cross_media_penalty_apps = applied_penalties.joins(:penalty).where(penalties: {type: "Global::Penalty"})
      music_specific_penalty_apps = applied_penalties.joins(:penalty).where(penalties: {type: "Music::Penalty"})

      assert_operator cross_media_penalty_apps.count, :>, 0, "Should have cross-media penalties via penalty_applications"
      assert_operator music_specific_penalty_apps.count, :>, 0, "Should have music-specific penalties via penalty_applications"

      # Verify the list has penalty associations (list-level penalties)
      list_penalties = music_list.list_penalties.includes(:penalty)
      list_cross_media_penalties = list_penalties.joins(:penalty).where(penalties: {type: "Global::Penalty"})
      list_music_penalties = list_penalties.joins(:penalty).where(penalties: {type: "Music::Penalty"})

      assert_operator list_cross_media_penalties.count, :>, 0, "Should have cross-media penalties via list_penalties"
      assert_operator list_music_penalties.count, :>, 0, "Should have music-specific penalties via list_penalties"

      # Calculate weight
      weight = calculator.call

      # Verify weight calculation
      refute_nil weight
      assert_kind_of Integer, weight
      assert_operator weight, :>=, music_config.min_list_weight

      # Verify weight is less than base due to penalties
      base_weight = 100
      assert_operator weight, :<=, base_weight, "Weight should not exceed base weight"

      # Since we have both cross-media AND music-specific penalties at both levels,
      # weight should definitely be less than base (don't calculate exact due to dynamic penalties)
      assert_operator weight, :<, base_weight, "Weight should be reduced due to cross-media + music-specific penalties"

      # Verify weight was saved
      assert_equal weight, music_ranked_list.reload.weight
    end

    # Test median voter count calculation and usage in penalty calculation
    test "calculates median voter count from ranking configuration lists" do
      # Create a fresh ranking configuration
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Test Median Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create lists with different voter counts
      lists_data = [
        {voters: 10, name: "List 10 voters"},
        {voters: 25, name: "List 25 voters"},
        {voters: 50, name: "List 50 voters"},
        {voters: 100, name: "List 100 voters"},
        {voters: 1, name: "List 1 voter A"},
        {voters: 1, name: "List 1 voter B"},  # Should be condensed to single 1
        {voters: nil, name: "List no voters"}  # Should be excluded
      ]

      lists_data.each do |data|
        list = Music::Albums::List.create!(
          name: "#{data[:name]} #{SecureRandom.hex(4)}",
          status: :approved,
          number_of_voters: data[:voters]
        )

        RankedList.create!(
          list: list,
          ranking_configuration: test_config
        )
      end

      # Test median calculation
      # Original numbers: [1, 1, 10, 25, 50, 100]
      # After condensing 1s: [10, 25, 50, 100, 1]
      # Sorted: [1, 10, 25, 50, 100]
      # Median of 5 numbers (odd): middle element = 25
      median = test_config.median_voter_count
      assert_equal 25, median

      # Create a list with low voter count to test penalty calculation
      low_voter_list = Music::Albums::List.create!(
        name: "Low Voter List #{SecureRandom.hex(4)}",
        status: :approved,
        number_of_voters: 5
      )

      low_voter_ranked_list = RankedList.create!(
        list: low_voter_list,
        ranking_configuration: test_config
      )

      # Add a voter count penalty
      voter_penalty = penalties(:dynamic_penalty)  # This is a number_of_voters dynamic penalty
      PenaltyApplication.create!(penalty: voter_penalty, ranking_configuration: test_config, value: 30)

      calculator = WeightCalculatorV1.new(low_voter_ranked_list)
      weight = calculator.call

      # The list should get a penalty because it has only 5 voters compared to median of 25
      assert_operator weight, :<, 100, "List with low voter count should have weight penalty"
    end

    # Test integration with existing fixtures
    test "works with existing fixture data" do
      # Test that the calculator works with the existing books_ranked_list fixture
      # binding.break
      weight = @calculator.call

      refute_nil weight
      assert_kind_of Integer, weight
      assert_operator weight, :>=, @books_config.min_list_weight

      # Verify weight was saved to the model
      assert_equal weight, @books_ranked_list.reload.weight
    end

    # Test temporal coverage penalty calculation for music
    test "calculates temporal coverage penalty for music lists" do
      # Create fresh music albums ranking configuration
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Temporal Penalty Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create music lists with different year coverage
      decade_list = Music::Albums::List.create!(
        name: "Best Albums of the 2010s",
        status: :approved,
        num_years_covered: 10  # Decade list
      )

      single_year_list = Music::Albums::List.create!(
        name: "Best Albums of 2020",
        status: :approved,
        num_years_covered: 1  # Single year
      )

      full_coverage_list = Music::Albums::List.create!(
        name: "Greatest Albums of All Time",
        status: :approved,
        num_years_covered: nil  # No temporal restriction
      )

      # Create a temporal coverage penalty
      temporal_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Limited Temporal Coverage",
        dynamic_type: :num_years_covered
      )

      PenaltyApplication.create!(
        penalty: temporal_penalty,
        ranking_configuration: test_config,
        value: 25  # 25% max penalty
      )

      # Create ranked lists
      decade_ranked = RankedList.create!(list: decade_list, ranking_configuration: test_config)
      single_year_ranked = RankedList.create!(list: single_year_list, ranking_configuration: test_config)
      full_coverage_ranked = RankedList.create!(list: full_coverage_list, ranking_configuration: test_config)

      # Calculate weights
      decade_weight = WeightCalculatorV1.new(decade_ranked).call
      single_year_weight = WeightCalculatorV1.new(single_year_ranked).call
      full_coverage_weight = WeightCalculatorV1.new(full_coverage_ranked).call

      # Full coverage (nil num_years_covered) should have no penalty
      assert_equal 100, full_coverage_weight, "Full coverage list should have no temporal penalty"

      # Single year should have more penalty than decade
      assert_operator single_year_weight, :<, decade_weight, "Single year list should have more penalty than decade list"
      assert_operator decade_weight, :<, full_coverage_weight, "Decade list should have some penalty compared to full coverage"

      # All weights should be reasonable (not zero or negative)
      assert_operator single_year_weight, :>, 0, "Single year weight should be positive"
      assert_operator decade_weight, :>, 0, "Decade weight should be positive"
    end

    # Test music year range calculation with actual data
    test "calculates music year range from actual album and song data" do
      # Skip if no music data exists
      skip "No music data available" if Music::Album.where.not(release_year: nil).empty? && Music::Song.where.not(release_year: nil).empty?

      # Create a test music list to get access to the calculator methods
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Year Range Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      test_list = Music::Albums::List.create!(
        name: "Year Range Test List",
        status: :approved,
        num_years_covered: 10
      )

      test_ranked_list = RankedList.create!(list: test_list, ranking_configuration: test_config)
      calculator = WeightCalculatorV1.new(test_ranked_list)

      # Use send to access private method for testing
      year_range = calculator.send(:calculate_music_year_range)

      # Should be a reasonable number based on actual data
      assert_kind_of Integer, year_range
      assert_operator year_range, :>, 0, "Year range should be positive"
      assert_operator year_range, :<=, 200, "Year range should be reasonable (not more than 200 years)"

      # Verify it's calculated from actual data, not fallback
      album_years = Music::Album.where.not(release_year: nil).pluck(:release_year)
      song_years = Music::Song.where.not(release_year: nil).pluck(:release_year)
      all_years = (album_years + song_years).compact

      unless all_years.empty?
        expected_range = all_years.max - all_years.min + 1
        expected_range = [expected_range, Date.current.year - all_years.min + 1].max
        assert_equal expected_range, year_range, "Year range should match calculated range from actual data"
      end
    end

    # Test temporal penalty power curve calculation
    test "applies power curve to temporal coverage penalties" do
      # Create test configuration
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Power Curve Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create temporal penalty
      temporal_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Temporal Coverage Power Curve Test",
        dynamic_type: :num_years_covered
      )

      PenaltyApplication.create!(
        penalty: temporal_penalty,
        ranking_configuration: test_config,
        value: 40  # 40% max penalty
      )

      # Create lists with different coverage ratios
      # Assuming music year range is around 40 years (1985-2025 from earlier test)
      quarter_coverage_list = Music::Albums::List.create!(
        name: "Quarter Coverage List",
        status: :approved,
        num_years_covered: 10  # ~25% of total range
      )

      half_coverage_list = Music::Albums::List.create!(
        name: "Half Coverage List",
        status: :approved,
        num_years_covered: 20  # ~50% of total range
      )

      # Create ranked lists
      quarter_ranked = RankedList.create!(list: quarter_coverage_list, ranking_configuration: test_config)
      half_ranked = RankedList.create!(list: half_coverage_list, ranking_configuration: test_config)

      # Calculate weights
      quarter_weight = WeightCalculatorV1.new(quarter_ranked).call
      half_weight = WeightCalculatorV1.new(half_ranked).call

      # Half coverage should have higher weight than quarter coverage (less penalty)
      assert_operator half_weight, :>, quarter_weight, "Half coverage should have less penalty than quarter coverage"

      # Both should have some penalty (weight < 100)
      assert_operator quarter_weight, :<, 100, "Quarter coverage should have penalty"
      assert_operator half_weight, :<, 100, "Half coverage should have penalty"

      # Verify power curve effect: penalty difference should be non-linear
      # (this is a qualitative test since exact values depend on actual music data)
      penalty_difference = half_weight - quarter_weight
      assert_operator penalty_difference, :>, 0, "Power curve should create meaningful penalty differences"
    end

    # Test that temporal penalties are only applied when num_years_covered is present
    test "skips temporal penalty when num_years_covered is nil" do
      # Create test configuration with temporal penalty
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Nil Coverage Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      temporal_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Temporal Penalty Should Be Skipped",
        dynamic_type: :num_years_covered
      )

      PenaltyApplication.create!(
        penalty: temporal_penalty,
        ranking_configuration: test_config,
        value: 50  # High penalty that should be skipped
      )

      # Create list without temporal coverage
      unlimited_list = Music::Albums::List.create!(
        name: "Unlimited Time Coverage List",
        status: :approved,
        num_years_covered: nil  # No temporal restriction
      )

      unlimited_ranked = RankedList.create!(list: unlimited_list, ranking_configuration: test_config)
      weight = WeightCalculatorV1.new(unlimited_ranked).call

      # Should have full weight since temporal penalty is skipped
      assert_equal 100, weight, "List with nil num_years_covered should skip temporal penalty"
    end

    # Test temporal penalty combined with other penalties
    test "combines temporal penalty with other penalty types" do
      # Create test configuration
      test_config = Music::Albums::RankingConfiguration.create!(
        name: "Combined Penalties Test Config #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )

      # Create multiple penalty types
      temporal_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Temporal Coverage Penalty",
        dynamic_type: :num_years_covered
      )

      static_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Static Test Penalty"
        # No dynamic_type = static penalty
      )

      category_penalty = Global::Penalty.create!(
        type: "Global::Penalty",
        name: "Category Specific Penalty",
        dynamic_type: :category_specific
      )

      # Apply all penalties to configuration
      PenaltyApplication.create!(penalty: temporal_penalty, ranking_configuration: test_config, value: 15)
      PenaltyApplication.create!(penalty: static_penalty, ranking_configuration: test_config, value: 10)
      PenaltyApplication.create!(penalty: category_penalty, ranking_configuration: test_config, value: 12)

      # Create list with multiple penalty triggers
      multi_penalty_list = Music::Albums::List.create!(
        name: "Multiple Penalties List",
        status: :approved,
        num_years_covered: 5,  # Temporal penalty trigger
        category_specific: true  # Category penalty trigger
      )

      # Associate static penalty with list
      ListPenalty.create!(list: multi_penalty_list, penalty: static_penalty)

      # Create clean list for comparison
      clean_list = Music::Albums::List.create!(
        name: "Clean Comparison List",
        status: :approved,
        num_years_covered: nil,  # No temporal penalty
        category_specific: false  # No category penalty
      )

      # Create ranked lists
      multi_penalty_ranked = RankedList.create!(list: multi_penalty_list, ranking_configuration: test_config)
      clean_ranked = RankedList.create!(list: clean_list, ranking_configuration: test_config)

      # Calculate weights
      multi_penalty_weight = WeightCalculatorV1.new(multi_penalty_ranked).call
      clean_weight = WeightCalculatorV1.new(clean_ranked).call

      # Multi-penalty list should have significantly lower weight
      assert_operator multi_penalty_weight, :<, clean_weight, "List with multiple penalties should have lower weight"

      # Multi-penalty weight should still be reasonable (not zero)
      assert_operator multi_penalty_weight, :>, 0, "Combined penalties should not zero out weight"
      assert_operator multi_penalty_weight, :>=, test_config.min_list_weight, "Should respect minimum weight floor"

      # Clean list should have full weight (only gets static penalty if associated)
      assert_equal 100, clean_weight, "Clean list should have full weight"
    end
  end
end
