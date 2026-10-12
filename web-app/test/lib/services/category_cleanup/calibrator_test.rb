require "test_helper"

module Services
  module CategoryCleanup
    class CalibratorTest < ActiveSupport::TestCase
      LocationTask = ::Services::Ai::Tasks::CategoryCleanup::LocationTask

      setup do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(5)
        ::Books::Category.where(category_type: :location).update_all(deleted: true)
        @places = %w[Kilwa Orapa].map do |name|
          record = ::Books::Category.create!(name: name, category_type: :location)
          CategoryItem.create!(category: record, item: books_books(:war_and_peace))
          record
        end
      end

      def answer(key, chain)
        {key: key, verdict: "real_place", canonical_name: "x", merge_into: nil, parent_chain: chain,
         place_kind: "city", retype_to: nil, ambiguous: false, reason: ""}
      end

      def ai_result(results)
        ::Services::Ai::Result.new(success: true, data: {results: results})
      end

      test "measures how often batched answers agree with one-at-a-time answers and writes nothing" do
        one_by_one = [{"1" => answer("1", ["Tanzania"])}, {"1" => answer("1", ["Botswana"])}]
        batched = [{"1" => answer("1", ["Tanzania"]), "2" => answer("2", ["Namibia"])}]
        LocationTask.any_instance.stubs(:call).returns(*(one_by_one + batched).map { |r| ai_result(r) })

        result = Calibrator.call(run: "r1", category_type: "location", sample_size: 2, seed: 1, sizes: [1, 2])

        row = result.data[:sizes].sole
        assert_equal 2, row[:size]
        assert_equal 2, row[:compared]
        assert_in_delta 0.5, row[:agreement]
        assert_equal 1, row[:disagreements].size
        assert CategoryCleanupDecision.none?
      end

      test "the tail is sampled by own links, not the merged-in total" do
        # Kilwa has one own link but absorbs a proposed merge carrying 6 more,
        # which pushes its effective links past head_min.
        feeder = ::Books::Category.create!(name: "Kilwa Kisiwani", category_type: :location)
        6.times { |i| CategoryItem.create!(category: feeder, item: ::Books::Book.order(:id).offset(i).first) }
        CategoryCleanupDecision.create!(category: feeder, run: "r1", stage: "rules", action: :merge, decided_by: :rule,
          target_category: @places.first, category_snapshot: CategoryCleanupDecision.snapshot_of(feeder))
        LocationTask.any_instance.stubs(:call).returns(ai_result({"1" => answer("1", ["A"]), "2" => answer("2", ["A"])}))

        result = Calibrator.call(run: "r1", category_type: "location", sample_size: 10, seed: 1, sizes: [2, 1])

        assert_equal 2, result.data[:sample]
      end

      test "a null comparison key on both sides compares equal instead of crashing" do
        nil_answer = answer("1", ["???"]).merge(canonical_name: "???")
        LocationTask.any_instance.stubs(:call).returns(ai_result({"1" => nil_answer}), ai_result({"1" => nil_answer}),
          ai_result({"1" => nil_answer, "2" => nil_answer}))

        result = Calibrator.call(run: "r1", category_type: "location", sample_size: 2, seed: 1, sizes: [1, 2])

        assert_in_delta 1.0, result.data[:sizes].sole[:agreement]
      end

      test "a location retype and a location delete do not count as agreeing" do
        retype = answer("1", []).merge(verdict: "not_a_place", retype_to: "genre")
        delete = answer("1", []).merge(verdict: "not_a_place", retype_to: nil)
        LocationTask.any_instance.stubs(:call).returns(ai_result({"1" => retype}), ai_result({"1" => delete}),
          ai_result({"1" => delete, "2" => delete}))

        result = Calibrator.call(run: "r1", category_type: "location", sample_size: 2, seed: 1, sizes: [1, 2])

        assert_in_delta 0.5, result.data[:sizes].sole[:agreement]
      end

      test "subject signatures compare action and merge target" do
        ::Books::Category.where(category_type: :subject).update_all(deleted: true)
        2.times do |i|
          record = ::Books::Category.create!(name: "Subj #{i}", category_type: :subject)
          CategoryItem.create!(category: record, item: books_books(:war_and_peace))
        end
        subject = ->(action, into) { {key: "1", action: action, name: "x", merge_into: into, reason: ""} }
        ::Services::Ai::Tasks::CategoryCleanup::SubjectTask.any_instance.stubs(:call).returns(
          ai_result({"1" => subject.call("keep", nil)}), ai_result({"1" => subject.call("merge", "Fiction")}),
          ai_result({"1" => subject.call("delete", nil), "2" => subject.call("merge", "Fiction")})
        )

        result = Calibrator.call(run: "r1", category_type: "subject", sample_size: 2, seed: 1, sizes: [1, 2])

        assert_in_delta 0.5, result.data[:sizes].sole[:agreement]
      end
    end
  end
end
