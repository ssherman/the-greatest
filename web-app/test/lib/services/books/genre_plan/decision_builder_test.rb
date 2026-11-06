require "test_helper"

module Services
  module Books
    module GenrePlan
      class DecisionBuilderTest < ActiveSupport::TestCase
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

        test "each action becomes the decisions of spec section 4" do
          result = DecisionBuilder.call(plan: plan, assignments: @assignments)
          by = CategoryCleanupDecision.for_run("g1").where(stage: "genres").group_by(&:category_id)

          assert_equal %w[keep], by[@fantasy.id].map(&:action)
          assert_equal [["rename", "Science Fiction"]], by[@sf.id].map { |d| [d.action, d.new_name] }
          assert_equal %w[delete], by[@ebooks.id].map(&:action)
          ya = by[@ya.id].index_by(&:action)
          assert_equal Category.category_types["audience"], ya["retype"].new_category_type
          assert_equal "Young Adult", ya["rename"].new_name
          split = by[@sff.id].sole
          assert_equal "split", split.action
          assert_equal @sf.id, split.target_category_id
          assert_equal [@fantasy.id], split.extra_target_ids
          assert result.success?
        end

        test "a subject with a target_id merges into it" do
          decisions = {@ebooks.id => {"name" => "Ebooks", "action" => "subject", "as" => "Hockey", "target_id" => @hockey.id}}
          DecisionBuilder.call(plan: plan(decisions), assignments: @assignments)
          merge = CategoryCleanupDecision.find_by!(category: @ebooks, run: "g1")
          assert_equal [@hockey.id, "merge"], [merge.target_category_id, merge.action]
        end

        test "a subject without a target_id retypes and renames" do
          decisions = {@ebooks.id => {"name" => "Ebooks", "action" => "subject", "as" => "Digital"}}
          DecisionBuilder.call(plan: plan(decisions), assignments: @assignments)
          rows = CategoryCleanupDecision.for_run("g1").where(category: @ebooks).index_by(&:action)
          assert_equal Category.category_types["subject"], rows["retype"].new_category_type
          assert_equal "Digital", rows["rename"].new_name
        end

        test "split answers become ids; unknown answers are left out" do
          book = books_books(:war_and_peace)
          other = books_books(:crime_and_punishment)
          @assignments = Assignments.new([[book.id, @sff.id, ["Fantasy"]], [other.id, @sff.id, :unknown]])

          DecisionBuilder.call(plan: plan, assignments: @assignments)

          split = CategoryCleanupDecision.find_by!(category: @sff, run: "g1")
          assert_equal({book.id.to_s => [@fantasy.id]}, split.split_assignments)
        end

        test "a renaming split names its primary" do
          history = ::Books::Category.create!(name: "History and Politics", category_type: :genre)
          decisions = {history.id => {"name" => "History and Politics", "action" => "split",
                                      "into" => ["History", {"subject" => "Hockey", "target_id" => @hockey.id}]}}

          DecisionBuilder.call(plan: plan(decisions, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "History"]), assignments: @assignments)

          split = CategoryCleanupDecision.find_by!(category: history, run: "g1")
          assert_nil split.target_category_id
          assert_equal "History", split.new_name
          assert_equal [@hockey.id], split.extra_target_ids
        end

        test "a split whose primary is an audience name merges into the audience producer" do
          mixed = ::Books::Category.create!(name: "Kids and teens", category_type: :genre)
          decisions = {mixed.id => {"name" => "Kids and teens", "action" => "split", "into" => ["Young Adult", "Fantasy"]}}

          DecisionBuilder.call(plan: plan(decisions), assignments: @assignments)

          split = CategoryCleanupDecision.find_by!(category: mixed, run: "g1")
          assert_equal [@ya.id, nil], [split.target_category_id, split.new_name]
          assert_equal [@fantasy.id], split.extra_target_ids
        end

        test "keep with also stores the extra targets" do
          decisions = {@fantasy.id => {"name" => "Fantasy", "action" => "keep", "also" => ["Science Fiction"]}}
          DecisionBuilder.call(plan: plan(decisions), assignments: @assignments)
          assert_equal [@sf.id], CategoryCleanupDecision.find_by!(category: @fantasy, run: "g1").extra_target_ids
        end

        test "a second build writes nothing" do
          DecisionBuilder.call(plan: plan, assignments: @assignments)
          assert_no_difference -> { CategoryCleanupDecision.count } do
            assert_equal 0, DecisionBuilder.call(plan: plan, assignments: @assignments).data[:created]
          end
        end

        test "books on a split genre with no answer are counted" do
          CategoryItem.create!(category: @sff, item: books_books(:war_and_peace))
          assert_equal 1, DecisionBuilder.call(plan: plan, assignments: @assignments).data[:unassigned_split_books]
        end
      end
    end
  end
end
