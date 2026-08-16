require "test_helper"

module Books
  class CollectionsRoutesTest < ActionDispatch::IntegrationTest
    # The books routes live behind a DomainConstraint, and the low-level
    # routing assertions below build a bare Rack::MockRequest (defaulting to
    # host "example.org") rather than honouring host! -- so every path here
    # is a full URL, matching the established pattern in
    # books_filters_routing_test.rb / books_browse_routing_test.rb.
    HOST = Rails.application.config.domains[:books]

    test "every registered collection has a route" do
      Collections::Registry.slugs(:books).each do |slug|
        assert_recognizes({controller: "books/ranked_items", action: "index", collection: slug},
          {path: "http://#{HOST}/#{slug}", method: :get})
      end
    end

    test "a bare collection routes to the ranked index" do
      assert_routing({method: :get, path: "http://#{HOST}/africa"},
        controller: "books/ranked_items", action: "index", collection: "africa")
    end

    test "a collection with a category and a date range routes" do
      assert_routing({method: :get, path: "http://#{HOST}/africa/the-greatest/fiction/books/from/1900/to/2000"},
        controller: "books/ranked_items", action: "index", collection: "africa",
        category_id: "fiction", published_start: "1900", published_end: "2000")
    end

    test "the full legacy grammar with a category, a date, and a page routes" do
      assert_routing({method: :get, path: "http://#{HOST}/africa/the-greatest/fiction/books/since/2000/page/2"},
        controller: "books/ranked_items", action: "index", collection: "africa",
        category_id: "fiction", published_start: "2000", page: "2")
    end

    test "an unknown collection slug does not route" do
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path("http://#{HOST}/antarctica", method: :get)
      end
    end
  end
end
