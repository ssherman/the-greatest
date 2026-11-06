require "test_helper"

module Services
  module Books
    module GenrePlan
      # Spec §10: the committed genre_plan.yml (PR 2 ships only data files)
      # passes the Validator's structure checks. These need no database, so ids
      # and live rows are not compared: live genres, target ids, protected ids
      # and the audiences that already exist are left to `apply`'s own run of the
      # full Validator.
      class CommittedPlanTest < ActiveSupport::TestCase
        def structure_errors(plan_path, assignments_path)
          Validator.structure_errors(plan: PlanFile.load(plan_path), assignments: Assignments.load(assignments_path))
        end

        test "the committed plan file is structurally valid" do
          skip "no #{PlanFile::DEFAULT_PATH}: the plan ships in a later PR" unless PlanFile::DEFAULT_PATH.exist?

          assert_empty structure_errors(PlanFile::DEFAULT_PATH, Assignments::DEFAULT_PATH)
        end

        test "a well-formed plan passes" do
          Dir.mktmpdir do |dir|
            plan_path = write_plan(dir, valid_data)

            assert_empty structure_errors(plan_path, File.join(dir, "none.csv"))
          end
        end

        test "a malformed plan fails every structure check" do
          data = valid_data
          data["audiences"] = data["audiences"].first(2)
          data["genres"] << {"name" => "fantasy", "definition" => "a duplicate, differing in case"}
          data["decisions"][1] = {"name" => "Sci-fi", "action" => "explode"}
          data["decisions"][2] = {"name" => "Fantasy", "action" => "merge", "into" => "Nowhere"}
          data["decisions"][3] = {"name" => "Kids", "action" => "audience", "as" => "Toddlers"}
          data["decisions"][4] = {"name" => "Romantasy", "action" => "keep", "also" => ["Fantasy", "Nowhere"]}
          data["decisions"][5] = {"name" => "Drama", "action" => "delete", "worldcat" => "Nowhere"}

          Dir.mktmpdir do |dir|
            errors = structure_errors(write_plan(dir, data), File.join(dir, "none.csv")).join("\n")

            assert_includes errors, "unknown action \"explode\""
            assert_includes errors, "audiences must be exactly"
            assert_includes errors, "duplicate names across the genre and audience lists: fantasy"
            assert_includes errors, "\"Nowhere\" is not on a list"
            assert_includes errors, "\"Toddlers\" is not an audience"
            assert_includes errors, "also must name other genres on the list"
            assert_includes errors, "worldcat \"Nowhere\" is not on a list"
            assert_includes errors, "Science Fiction is produced by no decision"
          end
        end

        test "an assignment outside its split's targets fails" do
          data = valid_data
          data["decisions"][6] = {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Science Fiction", "Fantasy"]}
          data["decisions"][1] = {"name" => "Science fiction", "action" => "rename", "to" => "Science Fiction"}

          Dir.mktmpdir do |dir|
            csv = File.join(dir, "assignments.csv")
            File.write(csv, "book_id,category_id,targets\n10,6,Fantasy\n11,6,Poetry\n12,99,Fantasy\n")

            errors = structure_errors(write_plan(dir, data), csv).join("\n")

            assert_includes errors, "book 11 on Science Fiction Fantasy: Poetry is not one of its targets"
            assert_includes errors, "split answers for 99, which is not a split"
            assert_not_includes errors, "book 10"
          end
        end

        private

        def write_plan(dir, data)
          path = File.join(dir, "plan.yml")
          File.write(path, data.to_yaml)
          path
        end

        def valid_data
          {"version" => 1, "run" => "g",
           "genres" => ["Science Fiction", "Fantasy", "Romantasy"].map { |name| {"name" => name, "definition" => "x"} },
           "audiences" => PlanFile::AUDIENCES.map { |name, d| {"name" => name, "definition" => d} },
           "decisions" => {
             1 => {"name" => "Science fiction", "action" => "rename", "to" => "Science Fiction"},
             2 => {"name" => "Fantasy", "action" => "keep"},
             3 => {"name" => "Romantasy", "action" => "keep", "also" => ["Fantasy"]},
             4 => {"name" => "Ebooks", "action" => "delete"},
             5 => {"name" => "Space Opera", "action" => "merge", "into" => "Science Fiction"}
           }}
        end
      end
    end
  end
end
