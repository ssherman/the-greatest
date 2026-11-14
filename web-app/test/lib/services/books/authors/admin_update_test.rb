require "test_helper"

module Services
  module Books
    module Authors
      class AdminUpdateTest < ActiveSupport::TestCase
        setup do
          @author = books_authors(:tolstoy)
          @user = users(:admin_user)
        end

        def call(attrs, **opts)
          AdminUpdate.call(author: @author, attrs: attrs, user: @user, via: "api", **opts)
        end

        test "present to blank writes a row stamped with the user and via" do
          result = call({"death_year" => nil})

          assert result.success?
          assert_includes result.data[:changed], "death_year"
          row = @author.cleared_fields.find_by!(field_name: "death_year")
          assert_equal [@user, "api"], [row.cleared_by, row.cleared_via]
        end

        test "blank to value deletes the row" do
          @author.update!(birth_year: nil)
          @author.cleared_fields.create!(field_name: "birth_year", cleared_via: :api)

          call({"birth_year" => 1830})

          refute @author.cleared_fields.exists?(field_name: "birth_year")
        end

        test "blank to blank writes no row without explicit_nulls and one with it" do
          @author.update!(birth_year: nil)

          call({"birth_year" => nil})
          refute @author.cleared_fields.exists?(field_name: "birth_year")

          call({"birth_year" => nil}, explicit_nulls: ["birth_year"])
          assert @author.cleared_fields.exists?(field_name: "birth_year")
        end

        test "a non-clearable field blanked writes no row" do
          call({"sort_name" => nil})

          assert_equal 0, @author.cleared_fields.count
        end

        test "a partial attrs leaves the other fields alone" do
          call({"sort_name" => "Tolstoy, Leo"})

          @author.reload
          assert_equal [1828, 1910, ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"]], [@author.birth_year, @author.death_year, @author.alternate_names]
        end

        test "alternate names are assigned" do
          call({"alternate_names" => ["Count Tolstoy"]})

          assert_equal ["Count Tolstoy"], @author.reload.alternate_names
        end

        test "a validation failure writes nothing" do
          result = call({"name" => "", "birth_year" => nil})

          refute result.success?
          assert_equal :invalid, result.data[:code]
          assert_equal [1828, 0], [@author.reload.birth_year, @author.cleared_fields.count]
        end
      end
    end
  end
end
