require "test_helper"

module Mcp
  class CompositeTest < ActiveSupport::TestCase
    class Sample < Mcp::Composite
      operations "getBook"
    end

    def catalog = Mcp::Catalog.for(document: :public, domain: :books)

    test "operations declares the ids and operation_ids reads them" do
      assert_equal ["getBook"], Sample.operation_ids
      assert_equal [], Class.new(Mcp::Composite).operation_ids
    end

    test "dispatch refuses an operation the composite did not declare" do
      assert_raises(ArgumentError) do
        Sample.dispatch(catalog, "listBooks", {}, principal: nil, request: nil)
      end
    end

    test "run must be implemented by a subclass" do
      assert_raises(NotImplementedError) { Sample.run(catalog, {}, principal: nil, request: nil) }
    end
  end
end
