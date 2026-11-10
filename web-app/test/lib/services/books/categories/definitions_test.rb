require "test_helper"

module Services
  module Books
    module Categories
      class DefinitionsTest < ActiveSupport::TestCase
        setup do
          @adventure = ::Books::Category.create!(name: "Adventure", category_type: :genre)
          @ya = ::Books::Category.create!(name: "Young Adult", category_type: :audience)
          @plan = Tempfile.new(["plan", ".yml"])
          @plan.write({"genres" => [{"name" => "adventure", "definition" => "A."}, {"name" => "Ghost", "definition" => "G."}],
                       "audiences" => [{"name" => "Young Adult", "definition" => "B."}]}.to_yaml)
          @plan.close
        end

        teardown { @plan.unlink }

        def run_it(apply:)
          Definitions.call(apply: apply, plan_path: @plan.path)
        end

        test "fills blank descriptions on the genre and the audience" do
          result = run_it(apply: true)

          assert result.success?
          assert_equal ["Adventure", "Young Adult"], result.data[:written].sort
          assert_equal "A.", @adventure.reload.description
          assert_equal "B.", @ya.reload.description
        end

        test "leaves a different non-blank description and reports it" do
          @adventure.update_columns(description: "Mine.")
          result = run_it(apply: true)

          assert_equal "Mine.", @adventure.reload.description
          assert_equal [{name: "Adventure", held: "Mine.", plan: "A."}], result.data[:kept]
        end

        test "reports an active genre with no plan entry and a blank description" do
          ::Books::Category.create!(name: "Western", category_type: :genre)
          ::Books::Category.create!(name: "Gone", category_type: :genre, deleted: true)
          ::Books::Category.create!(name: "Described", category_type: :genre).update_columns(description: "x")

          assert_equal ["Western"], run_it(apply: false).data[:missing]
        end

        test "a dry run writes nothing but reports the same names" do
          dry = run_it(apply: false)

          assert_nil @adventure.reload.description
          assert_equal run_it(apply: true).data[:written], dry.data[:written]
        end

        test "a second run writes nothing" do
          run_it(apply: true)

          assert_empty run_it(apply: true).data[:written]
        end

        test "matches by type, so a genre entry never fills an audience" do
          @adventure.update_columns(category_type: ::Books::Category.category_types[:audience])

          assert_equal ["Young Adult"], run_it(apply: true).data[:written]
        end
      end
    end
  end
end
