require "test_helper"

# The real guidance.yml, not a stub: penalties:load_guidance reads it in
# production, and a YAML syntax error there loads none of the guidance.
class PenaltyGuidanceFileTest < ActiveSupport::TestCase
  CONSOLIDATED_AWAY = [21, 27, 31, 32, 36, 37, 38, 39, 42].freeze

  setup do
    @entries = YAML.load_file(Rails.root.join("config/penalties/guidance.yml"))
  end

  test "parses to a list of entries with an integer id, a name and guidance" do
    assert_kind_of Array, @entries
    assert @entries.all? { |entry| entry.is_a?(Hash) }
    assert @entries.all? { |entry| entry["id"].is_a?(Integer) }
    assert @entries.all? { |entry| entry["name"].to_s.strip.present? && entry["guidance"].to_s.strip.present? }
  end

  test "ids are unique" do
    ids = @entries.map { |entry| entry["id"] }
    assert_equal ids.uniq, ids
  end

  test "carries the voter, location and mixed-voter penalties and none of the consolidated ones" do
    ids = @entries.map { |entry| entry["id"] }
    assert_empty [13, 14, 15, 18, 44, 46] - ids
    assert_empty CONSOLIDATED_AWAY & ids
  end
end
