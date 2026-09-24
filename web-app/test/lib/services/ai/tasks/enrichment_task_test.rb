require "test_helper"

module Services
  module Ai
    module Tasks
      class EnrichmentTaskTest < ActiveSupport::TestCase
        class ProbeTask < EnrichmentTask
          private

          def user_prompt = "probe"

          def response_schema = Schema

          class Schema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean
            required :confidence, String
            required :year, EnrichmentTask::IntegerFact
          end
        end

        def setup
          @book = books_books(:war_and_peace)
        end

        test "defaults to knowledge mode on the standard role with no tools" do
          task = ProbeTask.new(parent: @book)

          assert_equal :knowledge, task.mode
          refute task.research?
          assert_equal :standard, task.send(:task_role)
          assert_equal [], task.send(:tools)
          refute task.send(:force_tool?)
          assert_equal "gpt-6-sol", task.instance_variable_get(:@model)
        end

        test "research mode runs on the research role and forces web search" do
          task = ProbeTask.new(parent: @book, mode: :research)

          assert task.research?
          assert_equal :research, task.send(:task_role)
          assert_equal [:web_search], task.send(:tools)
          assert task.send(:force_tool?)
          assert_equal "gpt-6-astra", task.instance_variable_get(:@model)
        end

        test "rejects an unknown mode" do
          assert_raises(ArgumentError) { ProbeTask.new(parent: @book, mode: :guess) }
        end

        test "process_and_persist returns facts and citations and writes nothing" do
          task = ProbeTask.new(parent: @book)
          task.stubs(:chat).returns(ai_chats(:general_chat))
          before = @book.attributes

          result = task.send(:process_and_persist, {parsed: {recognized: true, confidence: "high", year: {value: 1869, confidence: "high"}}, citations: ["https://example.org"]})

          assert result.success?
          assert_equal({recognized: true, confidence: "high", year: {value: 1869, confidence: "high"}}, result.data[:facts])
          assert_equal ["https://example.org"], result.data[:citations]
          assert_equal ai_chats(:general_chat), result.ai_chat
          assert_equal before, @book.reload.attributes
        end

        test "process_and_persist tolerates a response without citations" do
          task = ProbeTask.new(parent: @book)
          task.stubs(:chat).returns(ai_chats(:general_chat))

          result = task.send(:process_and_persist, {parsed: {recognized: false, confidence: "low", year: {value: nil, confidence: "low"}}})

          assert_equal [], result.data[:citations]
        end

        test "fact schemas expose value and confidence" do
          schema = EnrichmentTask::IntegerFact.to_json_schema
          assert_equal %w[value confidence], schema[:properties].keys.map(&:to_s)
        end
      end
    end
  end
end
