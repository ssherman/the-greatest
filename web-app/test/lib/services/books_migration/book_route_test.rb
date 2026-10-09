require "test_helper"

class Services::BooksMigration::BookRouteTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def route(redirects: [], here: [10, 20], books_watermark: 1_000)
    Services::BooksMigration::BookRoute.new(
      sync_scope(redirects: redirects, books_watermark: books_watermark),
      book_ids_here: here.to_set
    )
  end

  test "a book that is here lands on itself" do
    assert_equal 10, route.call(10)
  end

  test "a merged book lands on its survivor" do
    assert_equal 20, route(redirects: [["Books::Book", 5, 20]]).call(5)
  end

  test "a deleted book is :deleted" do
    assert_equal :deleted, route(redirects: [["Books::Book", 5, nil]]).call(5)
  end

  test "a book above the watermark that is not here yet is :waiting" do
    assert_equal :waiting, route.call(1_001)
  end

  test "a book at or below the watermark that is neither here nor redirected is :missing" do
    assert_equal :missing, route.call(1_000)
    assert_equal :missing, route.call(7)
  end

  test "a merge into a book that is not here either is :missing" do
    assert_equal :missing, route(redirects: [["Books::Book", 5, 30]]).call(5)
  end

  test "an author redirect does not route a book" do
    assert_equal :missing, route(redirects: [["Books::Author", 5, 20]]).call(5)
  end

  test "lock is true when every book is still here" do
    book = ::Books::Book.create!(title: "Still Here")

    assert route(here: [book.id]).lock([book.id, book.id])
  end

  test "lock notices a book merged since the route was built, and reloads the redirects" do
    survivor = ::Books::Book.create!(title: "Survivor")
    stale = route(here: [200_001, survivor.id]) # built before the merge
    RecordRedirect.create!(item_type: "Books::Book", from_id: 200_001, to_id: survivor.id)

    refute stale.lock([200_001, survivor.id])
    assert_equal survivor.id, stale.call(200_001)
  end
end
