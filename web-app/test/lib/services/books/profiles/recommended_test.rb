require "test_helper"

module Services
  module Books
    module Profiles
      class RecommendedTest < ActiveSupport::TestCase
        setup do
          @user = users(:profile_reader)
        end

        def engine_result(items:)
          ::Recommendations::Engine::Result.new(success?: true, errors: [], data: {items: items.map { {item: it} }})
        end

        def stub_history(value)
          ::Recommendations::Books::Pages.any_instance.stubs(:history?).returns(value)
        end

        test "no_history when the user has no favorites, reads or ratings" do
          ::Recommendations::Engine.expects(:call).never

          data = Recommended.call(user: users(:profile_empty_reader))

          assert_equal [:no_history, []], [data.state, data.books]
        end

        test "ok with up to 6 books from the engine" do
          stub_history(true)
          books = ::Books::Book.limit(3).to_a
          ::Recommendations::Engine.expects(:call).with { |args| args[:limit] == 6 && args[:domain] == "books" }
            .returns(engine_result(items: books))

          data = Recommended.call(user: @user)

          assert_equal [:ok, books], [data.state, data.books]
        end

        test "unavailable when the engine result fails" do
          stub_history(true)
          ::Recommendations::Engine.stubs(:call).returns(::Recommendations::Engine::Result.new(success?: false, data: nil, errors: ["x"]))

          assert_equal :unavailable, Recommended.call(user: @user).state
        end

        test "unavailable when the engine returns no items" do
          stub_history(true)
          ::Recommendations::Engine.stubs(:call).returns(engine_result(items: []))

          assert_equal :unavailable, Recommended.call(user: @user).state
        end

        test "unavailable, not an exception, when the engine raises" do
          stub_history(true)
          ::Recommendations::Engine.stubs(:call).raises(RuntimeError, "boom")

          data = Recommended.call(user: @user)

          assert_equal [:unavailable, []], [data.state, data.books]
        end

        test "passes the user's stored engine overrides" do
          stub_history(true)
          config = stub(criteria_object: stub(engine_overrides: {depth: 7}))
          ::RecommendationConfig.subclass_for("books").stubs(:for_user).with(@user).returns(config)
          ::Recommendations::Engine.expects(:call).with { |args| args[:overrides] == {depth: 7} }
            .returns(engine_result(items: []))

          Recommended.call(user: @user)
        end
      end
    end
  end
end
