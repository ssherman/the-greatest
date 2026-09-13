# == Schema Information
#
# Table name: ranking_configurations
#
#  id                                 :bigint           not null, primary key
#  algorithm_version                  :integer          default(1), not null
#  apply_list_dates_penalty           :boolean          default(TRUE), not null
#  archived                           :boolean          default(FALSE), not null
#  bonus_pool_percentage              :decimal(10, 2)   default(3.0), not null
#  description                        :text
#  exponent                           :decimal(10, 2)   default(3.0), not null
#  global                             :boolean          default(TRUE), not null
#  inherit_penalties                  :boolean          default(TRUE), not null
#  last_refresh_error                 :text
#  last_refreshed_at                  :datetime
#  list_limit                         :integer
#  max_list_dates_penalty_age         :integer          default(50)
#  max_list_dates_penalty_percentage  :integer          default(80)
#  min_list_weight                    :integer          default(1), not null
#  name                               :string           not null
#  needs_refresh                      :boolean          default(FALSE), not null
#  primary                            :boolean          default(FALSE), not null
#  primary_mapped_list_cutoff_limit   :integer
#  published_at                       :datetime
#  refresh_requested_at               :datetime
#  refresh_status                     :integer          default(0), not null
#  secondary_mapped_list_cutoff_limit :integer
#  type                               :string           not null
#  user_shared                        :boolean          default(FALSE), not null
#  year                               :integer
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#  inherited_from_id                  :bigint
#  primary_mapped_list_id             :bigint
#  secondary_mapped_list_id           :bigint
#  user_id                            :bigint
#
# Indexes
#
#  index_ranking_configurations_on_inherited_from_id         (inherited_from_id)
#  index_ranking_configurations_on_primary_mapped_list_id    (primary_mapped_list_id)
#  index_ranking_configurations_on_secondary_mapped_list_id  (secondary_mapped_list_id)
#  index_ranking_configurations_on_type_and_global           (type,global)
#  index_ranking_configurations_on_type_and_primary          (type,primary)
#  index_ranking_configurations_on_type_and_user_id          (type,user_id)
#  index_ranking_configurations_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (inherited_from_id => ranking_configurations.id)
#  fk_rails_...  (primary_mapped_list_id => lists.id)
#  fk_rails_...  (secondary_mapped_list_id => lists.id)
#  fk_rails_...  (user_id => users.id)
#
require "test_helper"

class RankingConfigurationTest < ActiveSupport::TestCase
  def setup
    @user = users(:regular_user)
    @list = lists(:basic_list)
  end

  # Validations
  test "should be valid with required attributes" do
    config = RankingConfiguration.new(
      name: "Test Configuration",
      algorithm_version: 1,
      exponent: 3.0,
      bonus_pool_percentage: 3.0,
      min_list_weight: 1
    )
    assert config.valid?
  end

  test "should require name" do
    config = RankingConfiguration.new
    assert_not config.valid?
    assert_includes config.errors[:name], "can't be blank"
  end

  test "should validate algorithm_version is positive integer" do
    config = RankingConfiguration.new(name: "Test")
    config.algorithm_version = 0
    assert_not config.valid?
    config.algorithm_version = 1.5
    assert_not config.valid?
    config.algorithm_version = 1
    assert config.valid?
  end

  test "should validate exponent is positive and reasonable" do
    config = RankingConfiguration.new(name: "Test")
    config.exponent = 0
    assert_not config.valid?
    config.exponent = 11
    assert_not config.valid?
    config.exponent = 3.0
    assert config.valid?
  end

  test "should validate bonus_pool_percentage is between 0 and 100" do
    config = RankingConfiguration.new(name: "Test")
    config.bonus_pool_percentage = -1
    assert_not config.valid?
    config.bonus_pool_percentage = 101
    assert_not config.valid?
    config.bonus_pool_percentage = 3.0
    assert config.valid?
  end

  # Associations
  test "should belong to inherited_from ranking configuration" do
    parent = ranking_configurations(:books_global)
    child = RankingConfiguration.new(
      name: "Child Config",
      inherited_from: parent
    )
    assert_equal parent, child.inherited_from
  end

  test "should belong to user optionally" do
    # Global configurations can exist without a user
    config = RankingConfiguration.new(
      name: "Test",
      global: true
    )
    assert config.valid?

    # User-specific configurations must have a user
    config.global = false
    assert_not config.valid?

    config.user = @user
    assert config.valid?
  end

  test "should belong to mapped lists optionally" do
    config = RankingConfiguration.new(name: "Test")
    assert config.valid?

    config.primary_mapped_list = @list
    config.secondary_mapped_list = @list
    assert config.valid?
  end

  # Scopes
  test "should scope by global configurations" do
    global_configs = RankingConfiguration.global
    assert global_configs.all?(&:global?)
  end

  test "should scope by user specific configurations" do
    user_configs = RankingConfiguration.user_specific
    assert user_configs.all? { |c| !c.global? }
  end

  test "should scope by primary configurations" do
    primary_configs = RankingConfiguration.primary
    assert primary_configs.all?(&:primary?)
  end

  test "should scope by active configurations" do
    active_configs = RankingConfiguration.active
    assert active_configs.all? { |c| !c.archived? }
  end

  test "should scope by published configurations" do
    published_configs = RankingConfiguration.published
    assert published_configs.all?(&:published?)
  end

  test "should scope by type" do
    books_configs = RankingConfiguration.by_type("Books::RankingConfiguration")
    assert books_configs.all? { |c| c.type == "Books::RankingConfiguration" }
  end

  # Business Logic
  test "should ensure only one primary per type" do
    # First, unset any existing primary for this type
    RankingConfiguration.where(type: "Books::RankingConfiguration").update_all(primary: false)

    RankingConfiguration.create!(
      name: "Primary 1",
      type: "Books::RankingConfiguration",
      primary: true
    )

    config2 = RankingConfiguration.new(
      name: "Primary 2",
      type: "Books::RankingConfiguration",
      primary: true
    )

    assert_not config2.valid?
    assert_includes config2.errors[:primary], "can only have one primary configuration per type"
  end

  test "should allow primary configurations of different types" do
    # First, unset any existing primary for these types
    RankingConfiguration.where(type: "Books::RankingConfiguration").update_all(primary: false)
    RankingConfiguration.where(type: "Movies::RankingConfiguration").update_all(primary: false)

    RankingConfiguration.create!(
      name: "Books Primary",
      type: "Books::RankingConfiguration",
      primary: true
    )

    movies_config = RankingConfiguration.new(
      name: "Movies Primary",
      type: "Movies::RankingConfiguration",
      primary: true
    )

    assert movies_config.valid?
  end

  test "global configurations cannot have user" do
    config = RankingConfiguration.new(
      name: "Global Config",
      global: true,
      user: @user
    )
    assert_not config.valid?
    assert_includes config.errors[:user_id], "global configurations cannot have a user"
  end

  test "user specific configurations must have user" do
    config = RankingConfiguration.new(
      name: "User Config",
      global: false
    )
    assert_not config.valid?
    assert_includes config.errors[:user_id], "user-specific configurations must have a user"
  end

  test "inherited_from must be same type" do
    books_config = RankingConfiguration.create!(
      name: "Books Config",
      type: "Books::RankingConfiguration"
    )

    movies_config = RankingConfiguration.new(
      name: "Movies Config",
      type: "Movies::RankingConfiguration",
      inherited_from: books_config
    )

    assert_not movies_config.valid?
    assert_includes movies_config.errors[:inherited_from], "must be the same type"
  end

  # Instance Methods
  test "should check if published" do
    config = RankingConfiguration.new(name: "Test")
    assert_not config.published?

    config.published_at = Time.current
    assert config.published?
  end

  test "should check if inherited" do
    config = RankingConfiguration.new(name: "Test")
    assert_not config.inherited?

    config.inherited_from_id = 1
    assert config.inherited?
  end

  test "should check if can inherit from other config" do
    config1 = RankingConfiguration.create!(
      name: "Config 1",
      type: "Books::RankingConfiguration"
    )

    config2 = RankingConfiguration.new(
      name: "Config 2",
      type: "Books::RankingConfiguration"
    )

    assert config2.can_inherit_from?(config1)
    assert_not config1.can_inherit_from?(config1) # Can't inherit from self
  end

  test "should clone for inheritance" do
    # First, unset any existing primary for this type
    RankingConfiguration.where(type: "Books::RankingConfiguration").update_all(primary: false)

    original = RankingConfiguration.create!(
      name: "Original",
      type: "Books::RankingConfiguration",
      primary: true,
      published_at: Time.current
    )

    clone = original.clone_for_inheritance

    assert_equal original.id, clone.inherited_from_id
    assert_not clone.primary?
    assert_nil clone.published_at
    assert_equal original.name, clone.name
  end

  # Ranking Calculation Methods (new functionality)
  test "calculate_rankings returns result from calculator service" do
    config = ranking_configurations(:music_albums_global)

    result = config.calculate_rankings

    assert_instance_of ItemRankings::Calculator::Result, result
    assert_respond_to result, :success?
    assert_respond_to result, :data
    assert_respond_to result, :errors
  end

  test "calculate_rankings creates ranked items when successful" do
    config = ranking_configurations(:music_albums_global)
    config.ranked_items.destroy_all

    result = config.calculate_rankings

    if result.success?
      config.reload
      assert config.ranked_items.any?, "Should create ranked items on successful calculation"
    end
  end

  # Note: async job enqueueing tests removed to avoid test framework conflicts

  test "calculator_service returns correct calculator for music albums" do
    config = ranking_configurations(:music_albums_global)
    calculator = config.calculator_service

    assert_instance_of ItemRankings::Music::Albums::Calculator, calculator
    assert_equal config, calculator.ranking_configuration
  end

  test "calculator_service returns correct calculator for books" do
    config = ranking_configurations(:books_global)
    calculator = config.calculator_service

    assert_instance_of ItemRankings::Books::Calculator, calculator
    assert_equal config, calculator.ranking_configuration
  end

  test "calculator_service returns correct calculator for book authors" do
    config = ranking_configurations(:books_authors_global)
    calculator = config.calculator_service

    assert_instance_of ItemRankings::Books::Authors::Calculator, calculator
    assert_equal config, calculator.ranking_configuration
  end

  test "calculator_service returns correct calculator for movies" do
    config = ranking_configurations(:movies_global)
    calculator = config.calculator_service

    assert_instance_of ItemRankings::Movies::Calculator, calculator
    assert_equal config, calculator.ranking_configuration
  end

  test "calculator_service returns correct calculator for games" do
    config = ranking_configurations(:games_global)
    calculator = config.calculator_service

    assert_instance_of ItemRankings::Games::Calculator, calculator
    assert_equal config, calculator.ranking_configuration
  end

  test "calculator_service returns correct calculator for music songs" do
    config = ranking_configurations(:music_songs_global)
    calculator = config.calculator_service

    assert_instance_of ItemRankings::Music::Songs::Calculator, calculator
    assert_equal config, calculator.ranking_configuration
  end

  test "calculator_service raises error for unknown type" do
    config = ranking_configurations(:music_albums_global)
    # Stub the type to return an unknown value
    config.stubs(:type).returns("Unknown::Type")

    error = assert_raises StandardError do
      config.calculator_service
    end

    assert_includes error.message, "Unknown ranking configuration type: Unknown::Type"
  end

  test "calculator_service caches calculator instance" do
    config = ranking_configurations(:music_albums_global)

    calculator1 = config.calculator_service
    calculator2 = config.calculator_service

    assert_same calculator1, calculator2, "Should cache the calculator instance"
  end

  test "weight_floor mirrors the calculator's floor, not the raw stored minimum" do
    config = ranking_configurations(:books_global)

    config.min_list_weight = -50 # unreachable: total penalty caps at 100%, so weight never drops below 0
    assert_equal 0, config.weight_floor

    config.min_list_weight = 1 # reachable: music and games carry this, and a fully-penalised list lands here
    assert_equal 1, config.weight_floor

    config.min_list_weight = 0
    assert_equal 0, config.weight_floor
  end

  test "median_voter_count calculates correctly" do
    config = ranking_configurations(:music_albums_global)

    # This test depends on the fixture data having lists with voter counts
    median = config.median_voter_count

    # Should return a number or nil
    assert median.nil? || median.is_a?(Numeric), "Should return numeric value or nil"
  end

  # Integration test for the full ranking flow
  test "full ranking calculation flow works end to end" do
    config = ranking_configurations(:music_albums_global)
    config.ranked_items.destroy_all

    # Synchronous calculation
    result = config.calculate_rankings

    if config.ranked_lists.joins(:list).where(lists: {status: :active}).any?
      assert result.success?, "Ranking calculation should succeed when there are active lists"
      config.reload
      assert config.ranked_items.any?, "Should create ranked items"

      # Verify ranked items have correct structure
      ranked_item = config.ranked_items.first
      assert ranked_item.rank.present?, "Ranked item should have rank"
      assert ranked_item.score.present?, "Ranked item should have score"
      assert ranked_item.item_type == "Music::Album", "Should have correct item type"
      assert ranked_item.item.present?, "Should be associated with actual item"
    else
      # If no active lists, should still succeed but create no items
      assert result.success?, "Should succeed even with no active lists"
      assert config.ranked_items.empty?, "Should create no items when no active lists"
    end
  end

  test "year accepts nil" do
    config = ranking_configurations(:books_global)
    config.year = nil
    assert config.valid?
  end

  test "year rejects zero and non-integers" do
    config = ranking_configurations(:books_global)
    config.year = 0
    assert_not config.valid?
    assert_includes config.errors[:year], "must be greater than 0"

    config.year = 1.5
    assert_not config.valid?
    assert_includes config.errors[:year], "must be an integer"
  end

  test "secondary_mapped_list_cutoff_limit rejects zero" do
    config = ranking_configurations(:books_global)
    config.secondary_mapped_list_cutoff_limit = 0
    assert_not config.valid?
  end

  test "secondary_mapped_list_cutoff_limit accepts nil meaning uncapped" do
    config = ranking_configurations(:books_global)
    config.secondary_mapped_list_cutoff_limit = nil
    assert config.valid?
  end

  test "the four item domains support year rollups" do
    {
      books_global: ::Books::List,
      games_global: ::Games::List,
      music_albums_global: ::Music::Albums::List,
      music_songs_global: ::Music::Songs::List
    }.each do |fixture, list_class|
      config = ranking_configurations(fixture)
      assert config.supports_year_rollups?, "#{fixture} should support year rollups"
      assert_equal list_class, config.generated_list_class
    end
  end

  test "creator configurations do not support year rollups" do
    assert_not ranking_configurations(:books_authors_global).supports_year_rollups?
    assert_not ranking_configurations(:music_artists_global).supports_year_rollups?
  end

  test "generated_list_noun capitalises the media noun" do
    assert_equal "Books", ranking_configurations(:books_global).generated_list_noun
    assert_equal "Games", ranking_configurations(:games_global).generated_list_noun
    assert_equal "Albums", ranking_configurations(:music_albums_global).generated_list_noun
    assert_equal "Songs", ranking_configurations(:music_songs_global).generated_list_noun
  end

  test "only books names a static one-year penalty" do
    assert_equal "List: only covers 1 year (yearly book awards, best of the year, etc)",
      ranking_configurations(:books_global).one_year_penalty_name
    assert_nil ranking_configurations(:games_global).one_year_penalty_name
    assert_nil ranking_configurations(:music_albums_global).one_year_penalty_name
  end

  # --- user-owned configuration rules (spec §4, §11) ---

  test "user_owned? is the inverse of global?" do
    assert ranking_configurations(:books_user).user_owned?
    refute ranking_configurations(:books_global).user_owned?
  end

  test "refresh_status defaults to idle and exposes prefixed predicates" do
    config = ranking_configurations(:books_user)
    assert config.refresh_idle?
    refute config.refresh_in_progress?

    config.refresh_status = :queued
    assert config.refresh_in_progress?
    config.refresh_status = :running
    assert config.refresh_in_progress?
    config.refresh_status = :failed
    refute config.refresh_in_progress?
  end

  test "refresh_stale? is true only for an in-progress refresh older than the stale window" do
    config = ranking_configurations(:books_user)
    refute config.refresh_stale?

    config.assign_attributes(refresh_status: :running, refresh_requested_at: 30.minutes.ago)
    refute config.refresh_stale?
    refute config.refresh_claimable?

    config.refresh_requested_at = (RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago
    assert config.refresh_stale?
    assert config.refresh_claimable?
  end

  test "refresh_claimable? is true when idle or failed" do
    config = ranking_configurations(:books_user)
    assert config.refresh_claimable?
    config.refresh_status = :failed
    assert config.refresh_claimable?
  end

  # --- request_refresh! (spec §4) ---

  test "request_refresh! claims an idle configuration, clears the last error and enqueues the job" do
    config = ranking_configurations(:books_user)
    config.update_columns(last_refresh_error: "old")
    RankingConfigurations::RefreshJob.expects(:perform_async).with(config.id).once

    assert config.request_refresh!

    config.reload
    assert config.refresh_queued?
    assert_nil config.last_refresh_error
    assert_in_delta Time.current, config.refresh_requested_at, 5.seconds
  end

  test "request_refresh! claims a failed configuration" do
    config = ranking_configurations(:books_user)
    config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:failed])
    RankingConfigurations::RefreshJob.expects(:perform_async).once

    assert config.request_refresh!
  end

  test "request_refresh! returns false and enqueues nothing while a fresh refresh is in progress" do
    config = ranking_configurations(:books_user)
    config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running],
      refresh_requested_at: 5.minutes.ago)
    RankingConfigurations::RefreshJob.expects(:perform_async).never

    refute config.request_refresh!
    assert config.reload.refresh_running?
  end

  test "request_refresh! reclaims a refresh abandoned longer than the stale window" do
    config = ranking_configurations(:books_user)
    config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running],
      refresh_requested_at: (RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago)
    RankingConfigurations::RefreshJob.expects(:perform_async).once

    assert config.request_refresh!
    assert config.reload.refresh_queued?
  end

  test "only one of two back-to-back request_refresh! calls wins" do
    config = ranking_configurations(:books_user)
    RankingConfigurations::RefreshJob.expects(:perform_async).once

    assert config.request_refresh!
    refute RankingConfiguration.find(config.id).request_refresh!
  end

  test "max_list_dates_penalty_age is capped at 200 for every configuration" do
    config = ranking_configurations(:books_global)
    config.max_list_dates_penalty_age = 201
    refute config.valid?
    assert_includes config.errors[:max_list_dates_penalty_age], "must be less than or equal to 200"

    config.max_list_dates_penalty_age = 200
    assert config.valid?
  end

  test "min_list_weight must be 0..100 on a user-owned configuration only" do
    user_config = ranking_configurations(:books_user)
    user_config.min_list_weight = -1
    refute user_config.valid?
    user_config.min_list_weight = 101
    refute user_config.valid?
    user_config.min_list_weight = 100
    assert user_config.valid?

    global_config = ranking_configurations(:books_global)
    global_config.min_list_weight = -50
    assert global_config.valid?, "the books primary stores -50 and must stay valid"
  end

  test "description is capped at 1000 characters on a user-owned configuration only" do
    user_config = ranking_configurations(:books_user)
    user_config.description = "x" * 1001
    refute user_config.valid?

    global_config = ranking_configurations(:books_global)
    global_config.description = "x" * 1001
    assert global_config.valid?
  end

  test "a user-owned configuration cannot be primary" do
    config = ranking_configurations(:books_user)
    config.primary = true
    refute config.valid?
    assert_includes config.errors[:primary], "cannot be set on a user-owned configuration"
  end

  test "a user may own at most MAX_PER_USER configurations of one type" do
    user = users(:regular_user)
    existing = RankingConfiguration.where(type: "Books::RankingConfiguration", user_id: user.id).count
    (RankingConfiguration::MAX_PER_USER - existing).times do |i|
      Books::RankingConfiguration.create!(name: "Cap #{i}", global: false, user: user, min_list_weight: 0)
    end

    overflow = Books::RankingConfiguration.new(name: "One too many", global: false, user: user, min_list_weight: 0)
    refute overflow.valid?
    assert_includes overflow.errors[:base], "You can have at most #{RankingConfiguration::MAX_PER_USER} rankings"

    other_type = Games::RankingConfiguration.new(name: "Games is separate", global: false, user: user, min_list_weight: 0)
    assert other_type.valid?, "the cap is per configuration type"
  end

  test "the cap does not block updates to an existing configuration at the limit" do
    user = users(:regular_user)
    existing = RankingConfiguration.where(type: "Books::RankingConfiguration", user_id: user.id).count
    (RankingConfiguration::MAX_PER_USER - existing).times do |i|
      Books::RankingConfiguration.create!(name: "Cap #{i}", global: false, user: user, min_list_weight: 0)
    end

    config = ranking_configurations(:books_user)
    config.name = "Renamed at the cap"
    assert config.valid?
  end

  test "RANKING_SETTINGS names the six user-tunable attributes" do
    assert_equal %w[exponent bonus_pool_percentage min_list_weight apply_list_dates_penalty
      max_list_dates_penalty_age max_list_dates_penalty_percentage], RankingConfiguration::RANKING_SETTINGS
  end
end
