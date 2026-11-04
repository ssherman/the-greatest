require "test_helper"

module Services
  module Books
    module WorldCat
      class MergedDuplicatesTest < ActiveSupport::TestCase
        def record(oclc, merged = [])
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "merged_oclc" => merged)
        end

        test "drops a record whose number another record lists as merged" do
          kept = MergedDuplicates.reject([record(1, [2]), record(2), record(3)])
          assert_equal [1, 3], kept.map(&:oclc)
        end

        test "keeps everything when nothing is merged" do
          assert_equal [1, 2], MergedDuplicates.reject([record(1), record(2)]).map(&:oclc)
        end
      end
    end
  end
end
