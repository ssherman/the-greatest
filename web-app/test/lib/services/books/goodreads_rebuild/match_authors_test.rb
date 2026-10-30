# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class MatchAuthorsTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Breaking Free")
          @task_class = mock("task_class")
        end

        def add_author(name, position: 1, **attrs)
          ::Books::Author.create!(name: name, **attrs).tap { |author| @book.book_authors.create!(author: author, position: position) }
        end

        def facts(*names) = ExportFacts::Facts.new(title: "Breaking Free", full_title: "Breaking Free", year: 1991, author_names: names)

        def ai(*matches, success: true)
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: success, error: ("down" unless success), data: {matches: matches, reasoning: ""}))
          task
        end

        def match(name, number, confidence = "high") = {export_name: name, author_number: number, confidence: confidence}

        def call(*names) = MatchAuthors.call(book: @book, facts: facts(*names), task_class: @task_class)

        test "names equal to an author's name, alternate name or initials-folded name link without a call" do
          dennett = add_author("J.D. Dennett")
          vonnegut = add_author("Kurt Vonnegut", position: 2, alternate_names: ["Kurt Vonnegut Jr."])
          @task_class.expects(:new).never

          result = call("J. D. Dennett", "Kurt Vonnegut Jr.")

          assert result.success?
          assert_equal({"J. D. Dennett" => dennett.id, "Kurt Vonnegut Jr." => vonnegut.id}, result.data[:links])
          assert result.data[:all_matched]
        end

        test "a name the key does not match goes to the task, and a high answer links it" do
          dennett = add_author("Daniel Dennett")
          @task_class.expects(:new).with { |args| args[:export_names] == ["Daniel C. Dennett"] && args[:authors] == [dennett] && args[:book_id] == @book.id }
            .returns(ai(match("Daniel C. Dennett", 1)))

          result = call("Daniel C. Dennett")

          assert_equal({"Daniel C. Dennett" => dennett.id}, result.data[:links])
          assert result.data[:all_matched]
        end

        test "only the names without a direct match are sent to the task" do
          dennett = add_author("Daniel Dennett")
          add_author("Jane Roe", position: 2)
          @task_class.expects(:new).with { |args| args[:export_names] == ["Daniel C. Dennett"] }.returns(ai(match("Daniel C. Dennett", 1)))

          result = call("Daniel C. Dennett", "Jane Roe")

          assert_equal dennett.id, result.data[:links]["Daniel C. Dennett"]
          assert_equal 2, result.data[:links].size
        end

        test "a different person is not linked and the names are not all matched" do
          add_author("Roy Heath")
          @task_class.expects(:new).returns(ai(match("Chip Heath", nil)))

          result = call("Chip Heath")

          assert result.success?
          assert_equal({}, result.data[:links])
          refute result.data[:all_matched]
        end

        test "a medium or low answer is not a match" do
          add_author("Peter Brown")
          @task_class.expects(:new).returns(ai(match("Peter C. Brown", 1, "medium")))

          result = call("Peter C. Brown")

          assert_equal({}, result.data[:links])
          refute result.data[:all_matched]
        end

        test "one author is never linked to two names" do
          add_author("Peter Brown")
          @task_class.expects(:new).returns(ai(match("Peter C. Brown", 1), match("Pete Brown", 1)))

          assert_equal ["Peter C. Brown"], call("Peter C. Brown", "Pete Brown").data[:links].keys
        end

        test "two different high answers for one name link neither author" do
          add_author("Daniel Dennett")
          add_author("Daniel Clement Dennett", position: 2)
          @task_class.expects(:new).returns(ai(match("Daniel C. Dennett", 1), match("Daniel C. Dennett", 2)))

          result = call("Daniel C. Dennett")

          assert_equal({}, result.data[:links])
          refute result.data[:all_matched]
        end

        test "a task failure fails the result" do
          add_author("Roy Heath")
          @task_class.expects(:new).returns(ai(success: false))

          refute call("Chip Heath").success?
        end

        test "a book with no authors makes no call and links nothing" do
          @task_class.expects(:new).never

          result = call("Chip Heath")

          assert result.success?
          assert_equal({}, result.data[:links])
          refute result.data[:all_matched]
        end
      end
    end
  end
end
