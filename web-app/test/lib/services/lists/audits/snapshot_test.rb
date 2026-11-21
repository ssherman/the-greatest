require "test_helper"

module Services
  module Lists
    module Audits
      class SnapshotTest < ActiveSupport::TestCase
        setup do
          @list = lists(:books_list)
        end

        test "returns exactly the update fields" do
          result = Snapshot.call(@list)
          assert_equal Snapshot::FIELDS, result["fields"].keys
          assert_equal "Books Test List", result["fields"]["name"]
        end

        test "lists attached penalties sorted by id" do
          ::Penalty.where(type: %w[Books::Penalty Global::Penalty], user_id: nil).limit(2).each do |p|
            ListPenalty.find_or_create_by!(list: @list, penalty: p)
          end
          expected = @list.penalties.reload.order(:id).map { |p| {"id" => p.id, "name" => p.name} }
          assert expected.any?
          assert_equal expected, Snapshot.call(@list)["penalties"]
        end
      end
    end
  end
end
