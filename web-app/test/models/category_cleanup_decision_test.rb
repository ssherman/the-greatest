require "test_helper"

class CategoryCleanupDecisionTest < ActiveSupport::TestCase
  def decision(**attrs)
    CategoryCleanupDecision.new({category: categories(:books_france_location), run: "test", stage: "rules", action: :keep, decided_by: :rule}.merge(attrs))
  end

  test "a keep decision is valid and defaults to proposed" do
    record = decision
    assert record.valid?
    assert record.proposed?
  end

  test "a proposed rename needs a new name, a merge a target, a set_parent a chain, a retype a type" do
    refute decision(action: :rename).valid?
    refute decision(action: :merge).valid?
    refute decision(action: :set_parent).valid?
    refute decision(action: :retype).valid?
  end

  test "a failed decision may lack the fields a proposed one needs" do
    assert decision(action: :merge, status: :failed, error: "merge_into matches nothing").valid?
  end

  test "stage must be a known stage" do
    refute decision(stage: "whenever").valid?
  end

  test "terminal covers merge, retype and delete" do
    category = categories(:books_france_location)
    merge = CategoryCleanupDecision.create!(category: category, run: "t", stage: "rules", action: :merge, decided_by: :rule, target_category: categories(:books_american_location))
    retype = CategoryCleanupDecision.create!(category: category, run: "t", stage: "rules", action: :retype, decided_by: :rule, new_category_type: 2)
    delete = CategoryCleanupDecision.create!(category: category, run: "t", stage: "rules", action: :delete, decided_by: :rule)
    keep = CategoryCleanupDecision.create!(category: category, run: "t", stage: "rules", action: :keep, decided_by: :rule)

    assert_includes CategoryCleanupDecision.terminal, merge
    assert_includes CategoryCleanupDecision.terminal, retype
    assert_includes CategoryCleanupDecision.terminal, delete
    refute_includes CategoryCleanupDecision.terminal, keep
  end

  test "snapshot_of records the fields apply compares" do
    snapshot = CategoryCleanupDecision.snapshot_of(categories(:books_france_location))
    assert_equal %w[category_type deleted item_count name parent_id], snapshot.keys.sort
    assert_equal "France", snapshot["name"]
    assert_equal "location", snapshot["category_type"]
  end

  test "snapshot_of works on a record loaded with a limited select" do
    category = Category.select(:id, :name, :category_type, :alternative_names, :parent_id, :deleted, :item_count).find(categories(:books_france_location).id)
    snapshot = CategoryCleanupDecision.snapshot_of(category)
    assert_equal %w[category_type deleted item_count name parent_id], snapshot.keys.sort
    assert_equal "France", snapshot["name"]
  end

  test "hard-destroying a category removes decisions on either side without raising" do
    source = Books::Category.create!(name: "Cleanup Source", category_type: :genre)
    target = Books::Category.create!(name: "Cleanup Target", category_type: :genre)
    own = CategoryCleanupDecision.create!(category: source, run: "t", stage: "rules", action: :keep, decided_by: :rule)
    targeted = CategoryCleanupDecision.create!(category: categories(:books_france_location), run: "t", stage: "rules", action: :merge, decided_by: :rule, target_category: target)

    source.destroy!
    target.destroy!

    refute CategoryCleanupDecision.exists?(own.id)
    refute CategoryCleanupDecision.exists?(targeted.id)
  end
end
