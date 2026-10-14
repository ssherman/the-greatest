require "test_helper"

module Services
  module CategoryCleanup
    class AiPassTest < ActiveSupport::TestCase
      LocationTask = ::Services::Ai::Tasks::CategoryCleanup::LocationTask

      setup do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(2)
        # Fixture locations would otherwise join the candidate lists and the counts.
        ::Books::Category.where(category_type: :location).update_all(deleted: true)
        @us = location("United States", links: 2)
        @chicago = location("Chicago", links: 1)
        @boston = location("Boston", links: 1)
      end

      def location(name, links:)
        record = ::Books::Category.create!(name: name, category_type: :location)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def answer(key, name, chain)
        {key: key, verdict: "real_place", canonical_name: name, merge_into: nil, parent_chain: chain,
         place_kind: "city", retype_to: nil, ambiguous: false, reason: "r"}
      end

      def stub_task(results_by_call)
        calls = results_by_call.map do |results|
          ::Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: nil)
        end
        LocationTask.any_instance.stubs(:call).returns(*calls)
      end

      test "the head goes one category per call and writes ai decisions with a snapshot" do
        stub_task([{"1" => answer("1", "United States", [])}])

        result = AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal 1, result.data[:decided]
        decision = CategoryCleanupDecision.find_by!(run: "r1", category: @us)
        assert decision.decided_by_ai?
        assert_equal "locations_head", decision.stage
        assert_equal "United States", decision.category_snapshot["name"]
      end

      test "the tail batches, and a category missing from a batch answer is retried alone" do
        sizes = []
        results = [
          {"1" => answer("1", "Chicago", ["United States"])},
          {"1" => answer("1", "Boston", ["United States"])}
        ]
        LocationTask.stubs(:new).with { |**kwargs| sizes << kwargs[:entries].size }.returns(
          stub(call: ::Services::Ai::Result.new(success: true, data: {results: results[0]}, ai_chat: nil)),
          stub(call: ::Services::Ai::Result.new(success: true, data: {results: results[1]}, ai_chat: nil))
        )

        AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 2).call

        assert_equal [2, 1], sizes
        [@chicago, @boston].each do |category|
          assert_equal 1, CategoryCleanupDecision.where(run: "r1", category: category).count
          assert CategoryCleanupDecision.exists?(run: "r1", category: category, action: :set_parent)
        end
      end

      test "the tail still sends a category a head merge grew past the head threshold" do
        CategoryCleanupDecision.create!(category: @us, run: "r1", stage: "locations_head", action: :merge,
          target_category: @chicago, decided_by: :ai)
        assert_operator NameIndex.new(run: "r1", category_type: "location").entries.find { |e| e.id == @chicago.id }.links, :>=, 3
        stub_task([{"1" => answer("1", "Chicago", ["United States"])}, {"1" => answer("1", "Boston", ["United States"])}])

        result = AiPass.new(run: "r1", category_type: "location", tier: :tail).call

        assert_equal 2, result.data[:candidates]
        assert CategoryCleanupDecision.exists?(run: "r1", category: @chicago, stage: "locations_tail")
      end

      test "a head-sized category with no decision is not sent by the tail stage" do
        stub_task([{"1" => answer("1", "Chicago", ["United States"])}, {"1" => answer("1", "Boston", ["United States"])}])

        result = AiPass.new(run: "r1", category_type: "location", tier: :tail).call

        assert_equal 2, result.data[:candidates]
        assert_not CategoryCleanupDecision.exists?(run: "r1", category: @us)
      end

      test "the decision links the ai chat of the answer" do
        chat = ai_chats(:general_chat)
        LocationTask.any_instance.stubs(:call).returns(
          ::Services::Ai::Result.new(success: true, data: {results: {"1" => answer("1", "United States", [])}}, ai_chat: chat)
        )

        AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal chat, CategoryCleanupDecision.find_by!(run: "r1", category: @us).ai_chat
      end

      test "progress is reported every PROGRESS_EVERY calls with the running stats" do
        stub_const_every = AiPass::PROGRESS_EVERY
        AiPass.send(:remove_const, :PROGRESS_EVERY)
        AiPass.const_set(:PROGRESS_EVERY, 1)
        reports = []
        stub_task([{"1" => answer("1", "United States", [])}])

        AiPass.new(run: "r1", category_type: "location", tier: :head, progress: ->(stats) { reports << stats }).call

        assert_equal 1, reports.size
        assert_equal [1, 1, 1], [reports.first[:calls], reports.first[:candidates], reports.first[:decided]]
      ensure
        AiPass.send(:remove_const, :PROGRESS_EVERY)
        AiPass.const_set(:PROGRESS_EVERY, stub_const_every)
      end

      test "a rerun skips categories already decided in that stage" do
        stub_task([{"1" => answer("1", "United States", [])}])
        AiPass.new(run: "r1", category_type: "location", tier: :head).call

        LocationTask.any_instance.expects(:call).never
        result = AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal 0, result.data[:candidates]
      end

      test "categories removed by a rule decision are not sent" do
        CategoryCleanupDecision.create!(category: @chicago, run: "r1", stage: "rules", action: :delete, decided_by: :rule)
        stub_task([{"1" => answer("1", "Boston", ["United States"])}])

        result = AiPass.new(run: "r1", category_type: "location", tier: :tail).call

        assert_equal 1, result.data[:candidates]
      end

      test "a failed call writes nothing and is counted" do
        LocationTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: false, error: "timeout"))

        result = AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal 1, result.data[:failed_calls]
        assert CategoryCleanupDecision.where(run: "r1").none?
      end

      test "call_count reflects the pending candidates, the batch size and the limit" do
        assert_equal 1, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 25).call_count
        assert_equal 2, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 1).call_count
        assert_equal 1, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 1, limit: 1).call_count
        assert_equal 2, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 0).call_count
      end

      test "the tail batch size defaults to the configured size for the category type" do
        Rails.configuration.x.categories_cleanup.stubs(:tail_batch_size).returns({location: 2, subject: 1})
        assert_equal 1, AiPass.new(run: "r1", category_type: "location", tier: :tail).call_count

        Rails.configuration.x.categories_cleanup.stubs(:tail_batch_size).returns({location: 1, subject: 2})
        assert_equal 2, AiPass.new(run: "r1", category_type: "location", tier: :tail).call_count
      end
    end
  end
end
