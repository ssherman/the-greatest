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

        test "running it twice gives the same file, also lists included" do
          @path.write(YAML.safe_load_file(@path).tap { |m|
            m["terms"]["Art photography"] = {"verdict" => "genre", "genre" => "Art and Photography"}
            m["terms"]["Juvenile fantasy"] = {"verdict" => "genre", "genre" => "Fantasy Mix"}
          }.to_yaml)
          @plan.data["genres"].concat([{"name" => "Art"}, {"name" => "Photography"}, {"name" => "Fantasy"}])
          @plan.decisions[11] = {"name" => "Art and Photography", "action" => "split", "into" => ["Art", "Photography"],
                                 "worldcat_terms" => {"Art photography" => ["Art", "Photography"]}}
          @plan.decisions[12] = {"name" => "Art", "action" => "keep"}
          @plan.decisions[13] = {"name" => "Fantasy Mix", "action" => "split", "into" => ["Fantasy", "Children's"],
                                 "worldcat_terms" => {"Juvenile fantasy" => ["Fantasy", "Children's"]}}
          @plan.decisions[14] = {"name" => "Children's", "action" => "keep"}

          RetargetWorldCat.call(plan: @plan, path: @path)
          first = @path.read
          result = RetargetWorldCat.call(plan: @plan, path: @path)

          assert_equal first, @path.read
          assert_equal 0, result.data[:retargeted]
          assert_equal({"verdict" => "genre", "genre" => "Art", "also" => ["Photography"]}, terms["Art photography"])
          assert_equal({"verdict" => "audience", "audience" => "Children's", "weak" => true, "also" => ["Fantasy"]}, terms["Juvenile fantasy"])
        end

        test "a kept genre's also names reach its terms, as a union, and stay put on a second run" do
          @path.write(YAML.safe_load_file(@path).tap { |m|
            m["terms"]["Romantasy"] = {"verdict" => "genre", "genre" => "Romantasy"}
            m["terms"]["Romance fantasy"] = {"verdict" => "genre", "genre" => "Romantasy", "also" => ["Fantasy"]}
          }.to_yaml)
          @plan.data["genres"].concat([{"name" => "Romantasy"}, {"name" => "Romance"}, {"name" => "Fantasy"}])
          @plan.decisions[20] = {"name" => "Romantasy", "action" => "keep", "also" => ["Romance", "Fantasy"]}

          result = RetargetWorldCat.call(plan: @plan, path: @path)
          first = @path.read
          again = RetargetWorldCat.call(plan: @plan, path: @path)

          assert result.success?, result.errors.inspect
          assert_equal({"verdict" => "genre", "genre" => "Romantasy", "also" => ["Romance", "Fantasy"]}, terms["Romantasy"])
          assert_equal({"verdict" => "genre", "genre" => "Romantasy", "also" => ["Fantasy", "Romance"]}, terms["Romance fantasy"])
          assert_equal first, @path.read
          assert_equal 0, again.data[:retargeted]
        end

        def split_into_own_name
          @path.write(YAML.safe_load_file(@path).tap { |m|
            m["terms"]["Sci-fi"] = {"verdict" => "genre", "genre" => "Science Fiction"}
            m["terms"]["Hard SF"] = {"verdict" => "genre", "genre" => "Science Fiction"}
          }.to_yaml)
          @plan.data["genres"] << {"name" => "Fantasy"}
          @plan.decisions[30] = {"name" => "Science Fiction", "action" => "split", "into" => ["Science Fiction", "Fantasy"],
                                 "worldcat_terms" => {"Sci-fi" => ["Science Fiction", "Fantasy"], "Hard SF" => []}}
        end

        test "a split genre named like its own first target still answers from worldcat_terms" do
          split_into_own_name

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          assert result.success?, result.errors.inspect
          assert_equal({"verdict" => "genre", "genre" => "Science Fiction", "also" => ["Fantasy"]}, terms["Sci-fi"])
          assert_equal({"verdict" => "drop", "reason" => "not_a_genre"}, terms["Hard SF"])
        end

        test "terms an earlier run left in final form for the split's own name stay put, and a stranger still errors" do
          split_into_own_name

          first = RetargetWorldCat.call(plan: @plan, path: @path)
          again = RetargetWorldCat.call(plan: @plan, path: @path)

          assert first.success?, first.errors.inspect
          assert again.success?, again.errors.inspect
          assert_equal 0, again.data[:retargeted]
          assert_equal "Science Fiction", terms["Space operas"]["genre"]

          @path.write(YAML.safe_load_file(@path).tap { |m| m["terms"]["Stranger"] = {"verdict" => "audience", "audience" => "Science Fiction"} }.to_yaml)
          refute RetargetWorldCat.call(plan: @plan, path: @path).success?
        end

        test "a split genre named like its own first target is stable on a second run" do
          split_into_own_name

          RetargetWorldCat.call(plan: @plan, path: @path)
          first = @path.read
          again = RetargetWorldCat.call(plan: @plan, path: @path)

          assert again.success?, again.errors.inspect
          assert_equal first, @path.read
          assert_equal 0, again.data[:retargeted]
        end

        test "a renamed genre's also names reach its terms" do
          @path.write(YAML.safe_load_file(@path).tap { |m| m["terms"]["Romantic fantasy"] = {"verdict" => "genre", "genre" => "Romance fantasy"} }.to_yaml)
          @plan.data["genres"].concat([{"name" => "Romantasy"}, {"name" => "Romance"}, {"name" => "Fantasy"}])
          @plan.decisions[21] = {"name" => "Romance fantasy", "action" => "rename", "to" => "Romantasy", "also" => ["Romance", "Fantasy"]}

          RetargetWorldCat.call(plan: @plan, path: @path)

          assert_equal({"verdict" => "genre", "genre" => "Romantasy", "also" => ["Romance", "Fantasy"]}, terms["Romantic fantasy"])
        end

        test "also never repeats the primary or itself" do
          @path.write(YAML.safe_load_file(@path).tap { |m| m["terms"]["Art photography"] = {"verdict" => "genre", "genre" => "Art and Photography"} }.to_yaml)
          @plan.data["genres"].concat([{"name" => "Art"}, {"name" => "Photography"}])
          @plan.decisions[11] = {"name" => "Art and Photography", "action" => "split", "into" => ["Art", "Photography"],
                                 "worldcat_terms" => {"Art photography" => ["Art", "Photography", "Photography", "Art"]}}

          RetargetWorldCat.call(plan: @plan, path: @path)

          assert_equal({"verdict" => "genre", "genre" => "Art", "also" => ["Photography"]}, terms["Art photography"])
        end

        test "two decisions sharing a name that rewrite a term differently stop it" do
          @plan.decisions[15] = {"name" => "Drama", "action" => "keep"}

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          refute result.success?
          assert_match(/Drama/, result.errors.join)
        end

        test "a rewritten target missing from the headers stops it without writing" do
          @plan.decisions[3]["as"] = "Teen Zone"
          before = @path.read

          result = RetargetWorldCat.call(plan: @plan, path: @path)

          refute result.success?
          assert_match(/Teen Zone/, result.errors.join)
          assert_equal before, @path.read
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
