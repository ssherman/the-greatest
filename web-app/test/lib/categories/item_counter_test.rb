require "test_helper"

module Categories
  class ItemCounterTest < ActiveSupport::TestCase
    test "recomputes item_count from category_items for the given ids only" do
      france = categories(:books_france_location)
      politics = categories(:books_politics_subject)
      france.update_column(:item_count, 999)
      politics.update_column(:item_count, 999)

      ItemCounter.call([france.id])

      assert_equal CategoryItem.where(category_id: france.id).count, france.reload.item_count
      assert_equal 999, politics.reload.item_count
    end

    test "does nothing for an empty list" do
      assert_equal 0, ItemCounter.call([])
    end
  end
end
