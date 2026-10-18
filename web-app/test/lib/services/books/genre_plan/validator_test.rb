require "test_helper"

module Services
  module Books
    module GenrePlan
      class ValidatorTest < ActiveSupport::TestCase
        setup do
          @fiction = categories(:books_fiction_genre)
          @nonfiction = categories(:books_nonfiction_genre)
          ::Books::Category.stubs(:protected_ids).returns([@fiction.id, @nonfiction.id])
          ::Books::Category.where(category_type: :genre).where.not(id: [@fiction.id, @nonfiction.id]).update_all(deleted: true)
          @sf = ::Books::Category.create!(name: "Science fiction", category_type: :genre)
          @fantasy = ::Books::Category.create!(name: "Fantasy", category_type: :genre)
          @sff = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
          @ya = ::Books::Category.create!(name: "Young adult", category_type: :genre)
          @ebooks = ::Books::Category.create!(name: "Ebooks", category_type: :genre)
          @childrens = ::Books::Category.create!(name: "Children's books", category_type: :genre)
          @mg = ::Books::Category.create!(name: "Middle Grade", category_type: :genre)
          @hockey = ::Books::Category.create!(name: "Hockey", category_type: :subject)
          @assignments = Assignments.new([])
        end

        def plan(decisions = {}, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy"], **by_id)
          PlanFile.new({"run" => "g1",
            "genres" => genres.map { |name| {"name" => name, "definition" => "x"} },
            "audiences" => PlanFile::AUDIENCES.map { |name, d| {"name" => name, "definition" => d} },
            "decisions" => valid_decisions.merge(decisions).merge(by_id)})
        end

        def valid_decisions
          {@fiction.id => {"name" => "Fiction", "action" => "keep"},
           @nonfiction.id => {"name" => "Nonfiction", "action" => "keep"},
           @sf.id => {"name" => "Science fiction", "action" => "rename", "to" => "Science Fiction"},
           @fantasy.id => {"name" => "Fantasy", "action" => "keep"},
           @sff.id => {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Science Fiction", "Fantasy"]},
           @ya.id => {"name" => "Young adult", "action" => "audience", "as" => "Young Adult"},
           @childrens.id => {"name" => "Children's books", "action" => "audience", "as" => "Children's"},
           @mg.id => {"name" => "Middle Grade", "action" => "audience", "as" => "Middle Grade"},
           @ebooks.id => {"name" => "Ebooks", "action" => "delete"}}
        end

        def errors_for(plan) = Validator.call(plan: plan, assignments: @assignments).errors

        test "the valid plan passes" do
          assert_empty errors_for(plan)
        end

        test "a live genre missing from the plan is named" do
          late = ::Books::Category.create!(name: "Hockey Romance", category_type: :genre)
          assert_includes errors_for(plan).join("\n"), "#{late.id} Hockey Romance"
        end

        test "a decision whose name no longer matches the live row" do
          @fantasy.update!(name: "Fantasy!")
          assert_match(/live name is "Fantasy!"/, errors_for(plan).join("\n"))
        end

        test "a merge into a name not on the lists" do
          assert_match(/Space Opera/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "merge", "into" => "Space Opera"})).join("\n"))
        end

        test "a merge into Fiction is refused" do
          assert_match(/nothing merges into Fiction/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "merge", "into" => "Fiction"})).join("\n"))
        end

        test "a list genre nobody produces" do
          assert_match(/Horror.*produced by no decision/, errors_for(plan(genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "Horror"])).join("\n"))
        end

        test "a list genre produced twice" do
          errors = errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "rename", "to" => "Fantasy"}))
          assert_match(/Fantasy.*produced by 2 decisions/, errors.join("\n"))
        end

        test "a renaming split produces its primary" do
          history = ::Books::Category.create!(name: "History and Politics", category_type: :genre)
          decisions = {history.id => {"name" => "History and Politics", "action" => "split",
                                      "into" => ["History", {"subject" => "Hockey", "target_id" => @hockey.id}]}}

          assert_empty errors_for(plan(decisions, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "History"]))
        end

        test "a protected genre must be a plain keep" do
          assert_match(/Fiction is protected/, errors_for(plan(@fiction.id => {"name" => "Fiction", "action" => "rename", "to" => "Fictions"})).join("\n"))
        end

        test "the audiences must be exactly the three" do
          bad = plan
          bad.data["audiences"] = [{"name" => "Adult", "definition" => "x"}]
          assert_match(/audiences must be/, errors_for(bad).join("\n"))
        end

        test "a split needs at least two targets" do
          one = errors_for(plan(@sff.id => {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Fantasy"]}))
          assert_match(/at least two/, one.join("\n"))
        end

        test "a subject target_id must be a live subject with that name" do
          errors = errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "subject", "as" => "Hockey", "target_id" => @fantasy.id}))
          assert_match(/not a live subject/, errors.join("\n"))
        end

        test "a location needs a target_id" do
          assert_match(/needs a target_id/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "location", "as" => "Ohio"})).join("\n"))
        end

        test "also only on keep or rename, naming other list genres" do
          errors = errors_for(plan(@fantasy.id => {"name" => "Fantasy", "action" => "keep", "also" => ["Fantasy"]}))
          assert_match(/also/, errors.join("\n"))
        end

        test "worldcat must name a list entry" do
          errors = errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "delete", "worldcat" => "Plays"}))
          assert_match(/worldcat/, errors.join("\n"))
        end

        test "split answers must name the split's targets" do
          @assignments = Assignments.new([[1, @sff.id, ["Horror"]]])
          assert_match(/Horror/, errors_for(plan).join("\n"))
        end

        test "split answers for a genre that is not split" do
          @assignments = Assignments.new([[1, @fantasy.id, ["Fantasy"]]])
          assert_match(/not a split/, errors_for(plan).join("\n"))
        end

        test "a split cannot name a target twice" do
          errors = errors_for(plan(@sff.id => {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Fantasy", "Fantasy"]}))
          assert_match(/names a target twice/, errors.join("\n"))
        end

        test "a split cannot target a location" do
          ohio = ::Books::Category.create!(name: "Ohio", category_type: :location)
          into = ["Fantasy", {"subject" => "Ohio", "target_id" => ohio.id}]
          errors = errors_for(plan(@sff.id => {"name" => "Science Fiction Fantasy", "action" => "split", "into" => into}))
          assert_match(/not a live subject/, errors.join("\n"))
        end

        test "worldcat_terms must name the split's genres" do
          decision = {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Science Fiction", "Fantasy"],
                      "worldcat_terms" => {"space" => ["Horror"]}}
          assert_match(/worldcat_terms "space" names Horror/, errors_for(plan(@sff.id => decision)).join("\n"))
        end

        test "an empty worldcat_terms list is valid: the term is dropped at retarget" do
          decision = {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Science Fiction", "Fantasy"],
                      "worldcat_terms" => {"space" => []}}
          refute_match(/worldcat_terms/, errors_for(plan(@sff.id => decision)).join("\n"))
        end

        test "an unknown action" do
          assert_match(/unknown action "burn"/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "burn"})).join("\n"))
        end

        test "a decision on an id that is not a live genre" do
          assert_match(/999999.*not a live genre/, errors_for(plan(999_999 => {"name" => "Ghost", "action" => "delete"})).join("\n"))
        end

        test "a decision that is not a mapping is an error, not a crash" do
          assert_match(/must be a mapping/, errors_for(plan(@ebooks.id => nil)).join("\n"))
        end

        test "unknown split answers are accepted" do
          @assignments = Assignments.new([[1, @sff.id, :unknown]])
          assert_empty errors_for(plan)
        end

        test "an audience-name primary with no audience producer fails naming it" do
          teen = ::Books::Category.create!(name: "Teen Fantasy", category_type: :genre)
          decisions = {@ya.id => {"name" => "Young adult", "action" => "delete"},
                       teen.id => {"name" => "Teen Fantasy", "action" => "split", "into" => ["Young Adult", "Fantasy"]}}
          assert_match(/Young Adult is produced by no decision/, errors_for(plan(decisions)).join("\n"))
        end

        test "an audience-name primary beside an existing audience row passes" do
          ::Books::Category.create!(name: "Young Adult", category_type: :audience)
          teen = ::Books::Category.create!(name: "Teen Fantasy", category_type: :genre)
          decisions = {@ya.id => {"name" => "Young adult", "action" => "delete"},
                       @mg.id => {"name" => "Middle Grade", "action" => "delete"},
                       @childrens.id => {"name" => "Children's books", "action" => "delete"},
                       teen.id => {"name" => "Teen Fantasy", "action" => "split", "into" => ["Young Adult", "Fantasy"]}}
          errors = errors_for(plan(decisions))
          refute_match(/Young Adult/, errors.join("\n"))
        end

        test "duplicate list names, across lists too, are an error" do
          errors = errors_for(plan(genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "young adult"]))
          assert_match(/duplicate names/, errors.join("\n"))
        end

        test "also cannot name Fiction or Nonfiction" do
          errors = errors_for(plan(@fantasy.id => {"name" => "Fantasy", "action" => "keep", "also" => ["Nonfiction"]}))
          assert_match(/never Fiction or Nonfiction/, errors.join("\n"))
        end
      end
    end
  end
end
