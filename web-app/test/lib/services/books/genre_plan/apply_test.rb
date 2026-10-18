require "test_helper"

module Services
  module Books
    module GenrePlan
      class ApplyTest < ActiveSupport::TestCase
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

        test "with no plan file it says so and changes nothing" do
          result = Apply.call(plan: PlanFile.load(Rails.root.join("tmp", "missing.yml")), assignments: Assignments.new([]))
          refute result.success?
          assert_match(/no plan file/, result.errors.first)
        end

        test "an invalid plan writes nothing" do
          late = ::Books::Category.create!(name: "Hockey Romance", category_type: :genre)
          search = saved_searches(:books_public)
          search.update_column(:criteria, {"included_category_ids" => [@ebooks.id]})
          assert_no_difference -> { CategoryCleanupDecision.count } do
            result = Apply.call(plan: plan, assignments: @assignments)
            refute result.success?
            assert_match(/#{late.id} Hockey Romance/, result.errors.join)
          end
          assert_equal [@ebooks.id], search.reload.criteria["included_category_ids"]
          refute @ebooks.reload.deleted?
        end

        test "applies end to end, cleans saved searches of deleted genres, and is idempotent" do
          book = books_books(:war_and_peace)
          CategoryItem.create!(category: @sff, item: book)
          search = saved_searches(:books_public)
          search.update_column(:criteria, {"included_category_ids" => [@ebooks.id, @fantasy.id]})
          other = saved_searches(:books_private)
          other.update_column(:criteria, {"included_category_ids" => [@fantasy.id]})

          first = Apply.call(plan: plan, assignments: @assignments)
          assert first.success?, first.errors.inspect
          assert @ebooks.reload.deleted?
          assert_equal "Science Fiction", @sf.reload.name
          assert @ya.reload.audience?
          assert_equal "Young Adult", @ya.name
          assert_equal @sf, @sff.reload.merged_into
          assert CategoryItem.exists?(category: @fantasy, item: book)
          assert_equal [@fantasy.id], search.reload.criteria["included_category_ids"].map(&:to_i)
          assert_equal [@fantasy.id], other.reload.criteria["included_category_ids"]
          assert_equal [search.id], first.data[:cleaned][:saved_searches]

          assert_no_difference ["CategoryCleanupDecision.count", "CategoryItem.count"] do
            second = Apply.call(plan: plan, assignments: @assignments)
            assert second.success?, second.errors.inspect
          end
        end

        test "a blank run name fails without raising" do
          blank = PlanFile.new({"run" => "", "genres" => [], "audiences" => [], "decisions" => {}})
          result = Apply.call(plan: blank, assignments: @assignments)
          refute result.success?
          assert_match(/no run name/, result.errors.first)
        end

        test "a run that already has decisions from another stage is refused" do
          CategoryCleanupDecision.create!(category: @ebooks, run: "g1", stage: "rules", action: :delete,
            decided_by: :rule, category_snapshot: {})
          assert_no_difference -> { CategoryCleanupDecision.count } do
            result = Apply.call(plan: plan, assignments: @assignments)
            refute result.success?
            assert_match(/stage rules/, result.errors.first)
          end
        end

        test "the first apply is not a rerun and the second is" do
          assert_equal false, Apply.call(plan: plan, assignments: @assignments).data[:rerun]
          assert_equal true, Apply.call(plan: plan, assignments: @assignments).data[:rerun]
        end

        test "re-applying after a crash mid-apply completes without duplicates" do
          book = books_books(:war_and_peace)
          CategoryItem.create!(category: @sff, item: book)
          Services::CategoryCleanup::Applier.stubs(:call).raises("boom")
          assert_raises(RuntimeError) { Apply.call(plan: plan, assignments: @assignments) }
          Services::CategoryCleanup::Applier.unstub(:call)
          decisions = CategoryCleanupDecision.where(run: "g1").count
          assert_operator decisions, :>, 0

          result = Apply.call(plan: plan, assignments: @assignments)

          assert result.success?, result.errors.inspect
          assert_equal decisions, CategoryCleanupDecision.where(run: "g1").count
          assert @ebooks.reload.deleted?
          assert_equal 1, CategoryItem.where(category: @fantasy, item: book).count
          assert_equal 1, CategoryItem.where(category: @sf, item: book).count
        end

        def history_plan(extra_decisions, extra_genres: [])
          history = ::Books::Category.create!(name: "History and Politics", category_type: :genre)
          world = ::Books::Category.create!(name: "World History", category_type: :genre)
          politics = ::Books::Category.create!(name: "Politics", category_type: :subject)
          hp_book = books_books(:war_and_peace)
          wh_book = books_books(:crime_and_punishment)
          CategoryItem.create!(category: history, item: hp_book)
          CategoryItem.create!(category: world, item: wh_book)
          decisions = {history.id => {"name" => "History and Politics", "action" => "split",
                                      "into" => ["History", {"subject" => "Politics", "target_id" => politics.id}]}}
          decisions.merge!(extra_decisions.call(world))
          [history, world, politics, hp_book, wh_book, plan(decisions, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "History"] + extra_genres)]
        end

        test "a merge into a renaming split's primary does not tag the merged books with the other targets" do
          history, _world, politics, hp_book, wh_book, the_plan = history_plan(
            ->(world) { {world.id => {"name" => "World History", "action" => "merge", "into" => "History"}} }
          )
          result = Apply.call(plan: the_plan, assignments: Assignments.new([[hp_book.id, history.id, ["History"]]]))

          assert result.success?, result.errors.inspect
          refute CategoryItem.exists?(category: politics, item: hp_book)
          refute CategoryItem.exists?(category: politics, item: wh_book)
          assert CategoryItem.exists?(category: history, item: wh_book)
        end

        test "a rename with also into a renaming split's primary does not tag the renamed genre's books with the other targets" do
          history, _world, politics, hp_book, wh_book, the_plan = history_plan(
            ->(world) { {world.id => {"name" => "World History", "action" => "rename", "to" => "World Affairs", "also" => ["History"]}} },
            extra_genres: ["World Affairs"]
          )
          result = Apply.call(plan: the_plan, assignments: Assignments.new([[hp_book.id, history.id, ["History"]]]))

          assert result.success?, result.errors.inspect
          refute CategoryItem.exists?(category: politics, item: wh_book)
          assert CategoryItem.exists?(category: history, item: wh_book)
        end
      end
    end
  end
end
