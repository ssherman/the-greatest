require "test_helper"

module Services
  module Books
    module GenrePlan
      class PlanFileTest < ActiveSupport::TestCase
        test "a missing file loads empty" do
          plan = PlanFile.load(Rails.root.join("tmp", "no_such_plan.yml"))

          refute plan.exists?
          assert_empty plan.genres
          assert_empty plan.decisions
        end

        test "round-trips lists and integer-keyed decisions" do
          path = Rails.root.join("tmp", "genre_plan_test_#{SecureRandom.hex(4)}.yml")
          plan = PlanFile.new({"version" => 1, "run" => "genres-test",
            "genres" => [{"name" => "Fantasy", "definition" => "Magic."}],
            "audiences" => PlanFile::AUDIENCES.map { |name, definition| {"name" => name, "definition" => definition} },
            "decisions" => {12 => {"name" => "fantasy", "action" => "rename", "to" => "Fantasy"}}}, path: path)
          plan.write

          loaded = PlanFile.load(path)
          assert_equal "genres-test", loaded.run
          assert_equal ["Fantasy"], loaded.genre_names
          assert_equal PlanFile::AUDIENCES.keys, loaded.audience_names
          assert_equal "Fantasy", loaded.decisions[12]["to"]
          assert File.read(path).start_with?("# Books genre cleanup plan")
        ensure
          FileUtils.rm_f(path)
        end
      end
    end
  end
end
