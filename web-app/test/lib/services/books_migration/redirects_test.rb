require "test_helper"

class Services::BooksMigration::RedirectsTest < ActiveSupport::TestCase
  def redirects(rows)
    Services::BooksMigration::Redirects.new(rows)
  end

  test "an id with no redirect resolves to itself" do
    assert_equal 5, redirects([]).resolve("Books::Book", 5)
  end

  test "a merged id resolves to its survivor" do
    assert_equal 9, redirects([["Books::Book", 5, 9]]).resolve("Books::Book", 5)
  end

  test "follows a chain of merges to the final survivor" do
    assert_equal 12, redirects([["Books::Book", 5, 9], ["Books::Book", 9, 12]]).resolve("Books::Book", 5)
  end

  test "a deleted id resolves to :deleted, including at the end of a chain" do
    subject = redirects([["Books::Book", 5, nil], ["Books::Book", 6, 7], ["Books::Book", 7, nil]])

    assert_equal :deleted, subject.resolve("Books::Book", 5)
    assert_equal :deleted, subject.resolve("Books::Book", 6)
  end

  test "a cycle raises, naming the ids" do
    subject = redirects([["Books::Book", 5, 9], ["Books::Book", 9, 5]])

    error = assert_raises(RuntimeError) { subject.resolve("Books::Book", 5) }
    assert_includes error.message, "5 -> 9 -> 5"
  end

  test "keeps books and authors apart" do
    subject = redirects([["Books::Author", 5, 9]])

    assert_equal 5, subject.resolve("Books::Book", 5)
    refute subject.redirected?("Books::Book", 5)
    assert subject.redirected?("Books::Author", 5)
  end

  test "lists the redirected ids of one type" do
    subject = redirects([["Books::Book", 5, 9], ["Books::Book", 6, nil], ["Books::Author", 7, nil]])

    assert_equal Set[5, 6], subject.redirected_ids("Books::Book")
  end

  test "counts merges and deletes per type" do
    subject = redirects([["Books::Book", 5, 9], ["Books::Book", 6, nil], ["Books::Author", 7, nil]])

    assert_equal(
      {"Books::Book" => {merged: 1, deleted: 1}, "Books::Author" => {merged: 0, deleted: 1}},
      subject.counts
    )
  end

  test "load reads the record_redirects table" do
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    assert_equal 9, Services::BooksMigration::Redirects.load.resolve("Books::Book", 5)
  end
end
