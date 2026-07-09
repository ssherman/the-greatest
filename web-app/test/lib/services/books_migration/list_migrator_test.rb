require "test_helper"

module Services
  module BooksMigration
    class ListMigratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
      end

      def run_migrator(rows)
        migrator = ListMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 990001,
          "name" => "Best Books",
          "description" => "desc",
          "source" => "example.com",
          "url" => "https://example.com/list",
          "status" => 2,
          "year_published" => 2020,
          "number_of_voters" => 100,
          "estimated_quality" => 5,
          "submitted_by_id" => @user.id,
          "high_quality_source" => true,
          "category_specific" => false,
          "location_specific" => nil,
          "yearly_award" => false,
          "voter_count_unknown" => nil,
          "voter_names_unknown" => nil,
          "raw_html" => "<ol><li>A</li></ol>",
          "formatted_text" => "A",
          "created_at" => Time.utc(2015, 1, 2, 3, 4, 5),
          "updated_at" => Time.utc(2016, 2, 3, 4, 5, 6)
        }.merge(overrides)
      end

      test "maps a legacy list to Books::List, preserving id" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "Books::List", result[:data][:model]

        list = List.find(990001)
        assert_instance_of Books::List, list
        assert_equal "Best Books", list.name
        assert_equal "desc", list.description
        assert_equal "example.com", list.source
        assert_equal "https://example.com/list", list.url
        assert list.active?
        assert_equal 2020, list.year_published
        assert_equal 100, list.number_of_voters
        assert_equal 5, list.estimated_quality
        assert_equal @user, list.submitted_by
        assert_equal true, list.high_quality_source
        assert_equal false, list.category_specific
        assert_nil list.location_specific
        assert_equal "<ol><li>A</li></ol>", list.raw_content
        assert_equal "A", list.simplified_content
        assert_nil list.items_json
        assert_equal Time.utc(2015, 1, 2, 3, 4, 5), list.created_at
        assert_equal Time.utc(2016, 2, 3, 4, 5, 6), list.updated_at
      end

      test "remaps status by symbol" do
        expected = {0 => "unapproved", 1 => "approved", 2 => "active", 3 => "rejected", 4 => "unapproved", 5 => "unapproved"}
        expected.each_with_index do |(old, want), i|
          run_migrator([legacy_row("id" => 991000 + i, "status" => old)])
          assert_equal want, List.find(991000 + i).status, "old status #{old}"
        end
      end

      test "does not run auto_simplify_content (preserves legacy formatted_text)" do
        run_migrator([legacy_row("id" => 992001, "raw_html" => "<div><script>x</script>Hello</div>", "formatted_text" => "LEGACY")])

        assert_equal "LEGACY", List.find(992001).simplified_content
      end

      test "fails loud on an unmapped status" do
        result = run_migrator([legacy_row("id" => 993001, "status" => 9)])

        refute result[:success]
        assert_match(/993001/, result[:error])
      end

      test "is idempotent on id" do
        run_migrator([legacy_row("id" => 994001)])

        assert_no_difference -> { List.count } do
          run_migrator([legacy_row("id" => 994001, "name" => "Renamed")])
        end
        assert_equal "Renamed", List.find(994001).name
      end
    end
  end
end
