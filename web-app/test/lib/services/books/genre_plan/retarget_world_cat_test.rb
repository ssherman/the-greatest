require "test_helper"

module Services
  module Books
    module GenrePlan
      class RetargetWorldCatTest < ActiveSupport::TestCase
        setup do
          @path = Rails.root.join("tmp", "genre_map_test_#{SecureRandom.hex(4)}.yml")
          @path.write({"version" => 1, "genres" => ["Science fiction", "Space Opera", "Children's books", "Drama", "Ebooks", "History and Politics", "Vegetarian", "Gay fiction"],
                       "terms" => {
                         "Science fiction" => {"verdict" => "genre", "genre" => "Science fiction", "uses" => 9, "books" => 3, "language" => "en"},
                         "Space operas" => {"verdict" => "genre", "genre" => "Space Opera"},
                         "Juvenile fiction" => {"verdict" => "genre", "genre" => "Children's books"},
                         "Children's stories" => {"verdict" => "genre", "genre" => "Children's books"},
                         "Drama" => {"verdict" => "genre", "genre" => "Drama"},
                         "Electronic books" => {"verdict" => "drop", "reason" => "format"},
                         "History" => {"verdict" => "genre", "genre" => "History and Politics"},
                         "Vegetarian cooking" => {"verdict" => "genre", "genre" => "Vegetarian"},
                         "Gay fiction" => {"verdict" => "genre", "genre" => "Gay fiction"},
                         "Ebook" => {"verdict" => "genre", "genre" => "Ebooks"}
                       }}.to_yaml)
          @plan = PlanFile.new({"run" => "g", "genres" => [{"name" => "Science Fiction"}, {"name" => "Plays"}, {"name" => "History"}],
            "audiences" => PlanFile::AUDIENCES.map { |n, d| {"name" => n, "definition" => d} },
            "decisions" => {
              1 => {"name" => "Science fiction", "action" => "rename", "to" => "Science Fiction"},
              2 => {"name" => "Space Opera", "action" => "merge", "into" => "Science Fiction"},
              3 => {"name" => "Children's books", "action" => "audience", "as" => "Children's"},
              4 => {"name" => "Drama", "action" => "delete", "worldcat" => "Plays"},
              5 => {"name" => "Ebooks", "action" => "delete"},
              6 => {"name" => "History and Politics", "action" => "split", "into" => ["History", {"subject" => "Politics", "target_id" => 9}],
                    "worldcat_terms" => {"History" => ["History"]}},
              7 => {"name" => "Vegetarian", "action" => "subject"},
              8 => {"name" => "Gay fiction", "action" => "subject", "as" => "LGBTQ+", "target_id" => 10}
            }})
        end

        teardown { FileUtils.rm_f(@path) }

        def terms = YAML.safe_load_file(@path)["terms"]

        test "rewrites every term from the plan" do
          result = RetargetWorldCat.call(plan: @plan, path: @path)

          assert result.success?, result.errors.inspect
          assert_equal({"verdict" => "genre", "genre" => "Science Fiction", "uses" => 9, "books" => 3, "language" => "en"}, terms["Science fiction"])
          assert_equal "Science Fiction", terms["Space operas"]["genre"]
          assert_equal({"verdict" => "audience", "audience" => "Children's", "weak" => true}, terms["Juvenile fiction"])
          assert_equal({"verdict" => "audience", "audience" => "Children's"}, terms["Children's stories"])
          assert_equal({"verdict" => "genre", "genre" => "Plays"}, terms["Drama"])
          assert_equal({"verdict" => "drop", "reason" => "not_a_genre"}, terms["Ebook"])
          assert_equal({"verdict" => "genre", "genre" => "History"}, terms["History"])
          assert_equal({"verdict" => "subject", "subject" => "Vegetarian"}, terms["Vegetarian cooking"])
          assert_equal({"verdict" => "subject", "subject" => "LGBTQ+"}, terms["Gay fiction"])
          assert_equal({"verdict" => "drop", "reason" => "format"}, terms["Electronic books"])
          map = YAML.safe_load_file(@path)
          assert_equal ["Science Fiction", "Plays", "History"], map["genres"]
          assert_equal PlanFile::AUDIENCES.keys, map["audiences"]
          assert_equal 9, result.data[:retargeted]
        end

        test "a split's second genre goes in also" do
          @plan.decisions[6]["into"] = ["History", "Politics"]
          @plan.data["genres"] << {"name" => "Politics"}
          @plan.decisions[6]["worldcat_terms"] = {"History" => ["History", "Politics"]}

          RetargetWorldCat.call(plan: @plan, path: @path)

          assert_equal({"verdict" => "genre", "genre" => "History", "also" => ["Politics"]}, terms["History"])
        end

        test "a split term answered with no targets is dropped" do
          @plan.decisions[6]["worldcat_terms"] = {"History" => []}

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          assert result.success?, result.errors.inspect
          assert_equal({"verdict" => "drop", "reason" => "not_a_genre"}, terms["History"])
        end

        test "a juvenile split term puts Children's first and weak, the rest in also" do
          @path.write(YAML.safe_load_file(@path).tap { |m| m["terms"]["Juvenile fantasy"] = {"verdict" => "genre", "genre" => "Fantasy Mix"} }.to_yaml)
          @plan.decisions[9] = {"name" => "Fantasy Mix", "action" => "split", "into" => ["Fantasy", "Children's"],
                                "worldcat_terms" => {"Juvenile fantasy" => ["Fantasy", "Children's"]}}
          @plan.data["genres"] << {"name" => "Fantasy"}

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          assert result.success?, result.errors.inspect
          assert_equal({"verdict" => "audience", "audience" => "Children's", "weak" => true, "also" => ["Fantasy"]}, terms["Juvenile fantasy"])
        end

        test "running it twice gives the same file" do
          RetargetWorldCat.call(plan: @plan, path: @path)
          first = @path.read
          result = RetargetWorldCat.call(plan: @plan, path: @path)
          assert_equal first, @path.read
          assert_equal 0, result.data[:retargeted]
        end

        test "a term on a split genre missing from worldcat_terms stops it" do
          @plan.decisions[6]["worldcat_terms"] = {}
          before = @path.read

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          refute result.success?
          assert_match(/History/, result.errors.join)
          assert_equal before, @path.read
        end

        test "a term aimed at a genre the plan does not know stops it" do
          @path.write(YAML.safe_load_file(@path).tap { |m| m["terms"]["Mystery term"] = {"verdict" => "genre", "genre" => "Nowhere"} }.to_yaml)

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          refute result.success?
          assert_match(/Nowhere/, result.errors.join)
        end
      end
    end
  end
end
