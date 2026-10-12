require "test_helper"

module Books
  class LocationTrailsTest < ActiveSupport::TestCase
    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    test "builds each trail up to, but not including, the root" do
      na = location("North America")
      us = location("United States", parent: na)
      il = location("Illinois", parent: us)
      chicago = location("Chicago", parent: il)

      assert_equal [chicago, il, us], LocationTrails.call([chicago])[chicago.id]
    end

    test "a root on its own keeps itself" do
      france = location("France")
      assert_equal [france], LocationTrails.call([france])[france.id]
    end

    test "a soft-deleted ancestor ends the trail without dropping the last live place" do
      us = location("United States")
      il = location("Illinois", parent: us)
      chicago = location("Chicago", parent: il)
      us.update!(deleted: true)

      assert_equal [chicago, il], LocationTrails.call([chicago])[chicago.id]
    end
  end
end
