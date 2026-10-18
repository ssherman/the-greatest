require "test_helper"

module Services
  module Books
    module GenrePlan
      class SplitCheckTest < ActiveSupport::TestCase
        setup do
          @sff = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
          @lotr = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          [@lotr, @other].each { |book| CategoryItem.create!(category: @sff, item: book) }
          @plan = PlanFile.new({"run" => "g", "decisions" => {@sff.id => {"name" => @sff.name, "action" => "split", "into" => ["Science Fiction", "Fantasy"]}}})
          @path = Rails.root.join("tmp", "split_check_test_#{SecureRandom.hex(4)}.csv")
          @assignments = Assignments.load(@path)
        end

        teardown { FileUtils.rm_f(@path) }

        test "asks once per batch, writes every answer, and resumes" do
          ids = [@lotr.id, @other.id].sort
          answers = {"1" => ["Fantasy"], "2" => :unknown}
          Services::Ai::Tasks::Books::GenreSplitCheckTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {results: answers}))
          Services::CategoryCleanup::CostGuard.expects(:check!).with(calls: 1, force: false).returns(0.0)

          assert_equal 1, SplitCheck.calls_needed(plan: @plan, assignments: @assignments)
          result = SplitCheck.call(plan: @plan, assignments: @assignments)

          assert_equal [2, 1, 0], result.data.values_at(:checked, :calls, :failed_calls)
          loaded = Assignments.load(@path)
          assert_equal({ids[0] => ["Fantasy"], ids[1] => :unknown}, loaded.for(@sff.id))
          assert_equal 0, SplitCheck.calls_needed(plan: @plan, assignments: loaded)
        end

        test "a link to a book that no longer exists is skipped" do
          ghost = CategoryItem.new(category: @sff, item_type: "Books::Book", item_id: 999_999_999)
          ghost.save!(validate: false)
          Services::Ai::Tasks::Books::GenreSplitCheckTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {results: {"1" => ["Fantasy"], "2" => ["Fantasy"]}}))
          Services::CategoryCleanup::CostGuard.stubs(:check!).returns(0.0)

          result = SplitCheck.call(plan: @plan, assignments: @assignments)

          assert_equal [2, 0], result.data.values_at(:checked, :failed_calls)
          assert_not_includes Assignments.load(@path).for(@sff.id).keys, 999_999_999
        end

        test "a failed call appends nothing and is counted" do
          Services::Ai::Tasks::Books::GenreSplitCheckTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "bad"))
          Services::CategoryCleanup::CostGuard.stubs(:check!).returns(0.0)

          result = SplitCheck.call(plan: @plan, assignments: @assignments)

          assert_equal [0, 1, 1], result.data.values_at(:checked, :calls, :failed_calls)
          refute @path.exist?
        end

        test "the cost guard stops the run before any call" do
          Services::CategoryCleanup::CostGuard.stubs(:check!).raises(Services::CategoryCleanup::CostGuard::TooExpensive, "too much")
          Services::Ai::Tasks::Books::GenreSplitCheckTask.any_instance.expects(:call).never

          assert_raises(Services::CategoryCleanup::CostGuard::TooExpensive) { SplitCheck.call(plan: @plan, assignments: @assignments) }
        end
      end
    end
  end
end
