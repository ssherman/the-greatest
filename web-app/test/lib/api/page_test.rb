require "test_helper"

module Api
  class PageTest < ActiveSupport::TestCase
    def params(hash = {}) = ActionController::Parameters.new(hash)

    test "defaults to page 1 of 50" do
      page = Page.from_params(params, total_count: 120)

      assert_equal 1, page.page
      assert_equal 50, page.per_page
      assert_equal 0, page.offset
      assert_equal 3, page.total_pages
      assert_equal 2, page.next_page
      assert_nil page.prev_page
    end

    test "reads page and per_page from strings" do
      page = Page.from_params(params(page: "3", per_page: "25"), total_count: 120)

      assert_equal 3, page.page
      assert_equal 25, page.per_page
      assert_equal 50, page.offset
      assert_equal 5, page.total_pages
      assert_equal 4, page.next_page
      assert_equal 2, page.prev_page
    end

    test "an empty collection is one page with no neighbours" do
      page = Page.from_params(params, total_count: 0)

      assert_equal 1, page.total_pages
      assert_nil page.next_page
      assert_nil page.prev_page
    end

    test "a page past the end is allowed and points back at the last page" do
      page = Page.from_params(params(page: "99"), total_count: 120)

      assert_equal 99, page.page
      assert_nil page.next_page
      assert_equal 3, page.prev_page
    end

    test "rejects non-integers and out-of-range values with a message naming the parameter" do
      error = assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "abc"), total_count: 1) }
      assert_match(/page must be an integer between 1 and 2147483647/, error.message)

      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "0"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "-1"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "1.5"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "5_0"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "+1"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: " 1"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: (2**31).to_s), total_count: 1) }

      page = Page.from_params(params(page: (2**31 - 1).to_s), total_count: 1)
      assert_equal 2**31 - 1, page.page

      error = assert_raises(Page::InvalidParameter) { Page.from_params(params(per_page: "101"), total_count: 1) }
      assert_match(/per_page must be an integer between 1 and 100/, error.message)
      assert_raises(Page::InvalidParameter) { Page.from_params(params(per_page: "0"), total_count: 1) }
    end

    test "meta and links" do
      page = Page.from_params(params(page: "2", per_page: "10"), total_count: 35)

      assert_equal({page: 2, per_page: 10, total_count: 35, total_pages: 4}, page.meta)
      assert_equal(
        {
          self: "https://x.test/api/v1/books?page=2&per_page=10",
          next: "https://x.test/api/v1/books?page=3&per_page=10",
          prev: "https://x.test/api/v1/books?page=1&per_page=10",
          first: "https://x.test/api/v1/books?page=1&per_page=10",
          last: "https://x.test/api/v1/books?page=4&per_page=10"
        },
        page.links("https://x.test/api/v1/books")
      )
    end

    test "links carry nulls, not missing keys, when there is no next or prev" do
      links = Page.from_params(params, total_count: 3).links("https://x.test/api/v1/books")

      assert links.key?(:next)
      assert_nil links[:next]
      assert_nil links[:prev]
    end
  end
end
