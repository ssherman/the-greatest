require "test_helper"

module Services
  module Books
    module GenrePlan
      class AssignmentsTest < ActiveSupport::TestCase
        test "appends and reads back answers, with unknown" do
          path = Rails.root.join("tmp", "assignments_test_#{SecureRandom.hex(4)}.csv")
          Assignments.load(path).append([[1, 40, ["Fantasy"]], [2, 40, :unknown], [3, 40, ["Science Fiction", "Fantasy"]]])

          loaded = Assignments.load(path)
          assert_equal({1 => ["Fantasy"], 2 => :unknown, 3 => ["Science Fiction", "Fantasy"]}, loaded.for(40))
          assert loaded.answered?(40, 2)
          refute loaded.answered?(40, 9)
          assert_equal [40], loaded.category_ids
        ensure
          FileUtils.rm_f(path)
        end
      end
    end
  end
end
