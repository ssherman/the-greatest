require "test_helper"

class Services::BooksMigration::RankingConfigurationTransformerTest < ActiveSupport::TestCase
  T = Services::BooksMigration::RankingConfigurationTransformer

  def legacy(overrides = {})
    {
      "id" => 48,
      "name" => "The Best Books of 2024",
      "description" => "desc",
      "global" => true,
      "user_id" => 1,
      "primary" => false,
      "starting_score" => 200,
      "inherited_from_id" => nil,
      "inherit_list_cons" => false,
      "archived" => false,
      "published_at" => nil,
      "algorithm_version" => 4,
      "min_max_normalization" => false,
      "min_list_weight" => -50,
      "max_age_for_penalty" => nil,
      "max_penalty_percentage" => nil,
      "list_limit" => nil,
      "apply_list_dates_penalty" => false,
      "apply_global_age_penalty" => false,
      "list_cons_are_percentages" => true,
      "bonus_pool_percentage" => 2.0,
      "exponent" => 1.5,
      "primary_mapped_list_id" => 746,
      "secondary_mapped_list_id" => 747,
      "primary_mapped_list_cutoff_limit" => 100,
      "created_at" => Time.utc(2024, 12, 29, 17, 58, 25),
      "updated_at" => Time.utc(2026, 3, 21, 14, 57, 39)
    }.merge(overrides)
  end

  test "renames the penalty/inherit columns" do
    out = T.call(legacy("inherit_list_cons" => true, "max_age_for_penalty" => 50, "max_penalty_percentage" => 80))
    assert_equal true, out[:inherit_penalties]
    assert_equal 50, out[:max_list_dates_penalty_age]
    assert_equal 80, out[:max_list_dates_penalty_percentage]
  end

  test "drops user_id for a global config" do
    assert_nil T.call(legacy("global" => true, "user_id" => 1))[:user_id]
  end

  test "keeps user_id for a non-global config" do
    assert_equal 7, T.call(legacy("global" => false, "user_id" => 7))[:user_id]
  end

  test "forces archived false and omits type and inherited_from_id" do
    out = T.call(legacy("archived" => false))
    assert_equal false, out[:archived]
    assert_not out.key?(:type)
    assert_not out.key?(:inherited_from_id)
  end

  test "does not carry the dropped legacy columns" do
    out = T.call(legacy)
    [:starting_score, :min_max_normalization, :list_cons_are_percentages, :apply_global_age_penalty].each do |k|
      assert_not out.key?(k), "expected #{k} to be dropped"
    end
  end

  test "passes mapped-list ids and scoring fields straight through" do
    out = T.call(legacy)
    assert_equal 746, out[:primary_mapped_list_id]
    assert_equal 747, out[:secondary_mapped_list_id]
    assert_equal 100, out[:primary_mapped_list_cutoff_limit]
    assert_equal(-50, out[:min_list_weight])
    assert_equal 2.0, out[:bonus_pool_percentage]
    assert_equal 1.5, out[:exponent]
    assert_equal 4, out[:algorithm_version]
  end

  test "preserves timestamps" do
    out = T.call(legacy)
    assert_equal Time.utc(2024, 12, 29, 17, 58, 25), out[:created_at]
    assert_equal Time.utc(2026, 3, 21, 14, 57, 39), out[:updated_at]
  end
end
