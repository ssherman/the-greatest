require "test_helper"

module Services
  module Lists
    class AdminUpdateTest < ActiveSupport::TestCase
      setup do
        @list = lists(:books_list)
        @user = users(:admin_user)
      end

      def call(attrs, explicit_nulls: [])
        AdminUpdate.call(list: @list, attrs: attrs, user: @user, via: :api, explicit_nulls: explicit_nulls)
      end

      test "FIELDS is the one list of editable fields and never includes status or content" do
        assert_equal "name", AdminUpdate::FIELDS.first
        assert_equal "estimated_quality", AdminUpdate::FIELDS.last
        assert_empty AdminUpdate::FIELDS & %w[status raw_content simplified_content items_json wizard_state]
        assert_same AdminUpdate::FIELDS, Services::Lists::Audits::Snapshot::FIELDS
        assert_same AdminUpdate::FIELDS, ::Api::V1::Admin::Books::ListFullResource::FIELDS
      end

      test "saves the attributes and reports only the fields whose value changed" do
        result = call({"number_of_voters" => 12, "name" => @list.name, "voter_count_estimated" => true})

        assert result.success?
        assert_equal ["number_of_voters", "voter_count_estimated"], result.data[:changed]
        @list.reload
        assert_equal 12, @list.number_of_voters
        assert @list.voter_count_estimated
      end

      test "nil clears a nullable field" do
        result = call({"description" => nil}, explicit_nulls: ["description"])

        assert result.success?
        assert_equal ["description"], result.data[:changed]
        assert_nil @list.reload.description
      end

      test "clearing estimated_quality stores its default of 0 because the column is not null" do
        result = call({"estimated_quality" => nil}, explicit_nulls: ["estimated_quality"])

        assert result.success?
        assert_equal 0, @list.reload.estimated_quality
      end

      test "a failed validation returns the model's messages and writes nothing" do
        assert_no_changes -> { @list.reload.attributes } do
          result = call({"num_years_covered" => 0, "name" => "Renamed"})

          assert_not result.success?
          assert result.errors.any? { |message| message.include?("Num years covered") }
        end
      end
    end
  end
end
