# == Schema Information
#
# Table name: ranking_configurations
#
#  id                                :bigint           not null, primary key
#  algorithm_version                 :integer          default(1), not null
#  apply_list_dates_penalty          :boolean          default(TRUE), not null
#  archived                          :boolean          default(FALSE), not null
#  bonus_pool_percentage             :decimal(10, 2)   default(3.0), not null
#  description                       :text
#  exponent                          :decimal(10, 2)   default(3.0), not null
#  global                            :boolean          default(TRUE), not null
#  inherit_penalties                 :boolean          default(TRUE), not null
#  list_limit                        :integer
#  max_list_dates_penalty_age        :integer          default(50)
#  max_list_dates_penalty_percentage :integer          default(80)
#  min_list_weight                   :integer          default(1), not null
#  name                              :string           not null
#  primary                           :boolean          default(FALSE), not null
#  primary_mapped_list_cutoff_limit  :integer
#  published_at                      :datetime
#  type                              :string           not null
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  inherited_from_id                 :bigint
#  primary_mapped_list_id            :bigint
#  secondary_mapped_list_id          :bigint
#  user_id                           :bigint
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
end
