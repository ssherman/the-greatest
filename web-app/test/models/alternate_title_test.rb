require "test_helper"

class AlternateTitleTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
    @other = books_books(:crime_and_punishment)
    ::AlternateTitle.where(titleable: [@book, @other]).delete_all
  end

  test "normalized_title is set from title" do
    row = ::AlternateTitle.create!(titleable: @book, title: "“Don Quixote”", source: :admin)
    assert_equal ::Services::Books::Verification::Check.normalize("“Don Quixote”"), row.normalized_title
  end

  test "one row per book and normalized title" do
    ::AlternateTitle.create!(titleable: @book, title: "War and Peace", source: :legacy)
    assert_not ::AlternateTitle.new(titleable: @book, title: "WAR AND PEACE", source: :legacy).valid?
    assert ::AlternateTitle.new(titleable: @other, title: "WAR AND PEACE", source: :legacy).valid?
  end

  test "listed is kept and review in id order" do
    a = ::AlternateTitle.create!(titleable: @book, title: "A title", source: :legacy)
    ::AlternateTitle.create!(titleable: @book, title: "B title", source: :legacy, status: :removed)
    c = ::AlternateTitle.create!(titleable: @book, title: "C title", source: :legacy, status: :review)
    assert_equal [a.title, c.title], @book.alternate_title_records.listed.pluck(:title)
  end

  test "unjudged is kept without a verdict" do
    unjudged = ::AlternateTitle.create!(titleable: @book, title: "A title", source: :legacy)
    ::AlternateTitle.create!(titleable: @book, title: "B title", source: :legacy, verdict: :same_work)
    ::AlternateTitle.create!(titleable: @book, title: "C title", source: :legacy, status: :removed)
    assert_equal [unjudged], @book.alternate_title_records.unjudged.to_a
  end

  test "unjudged leaves out a row an admin already decided" do
    ::AlternateTitle.create!(titleable: @book, title: "A title", source: :legacy, decided_by: :admin, decided_at: Time.current)
    assert_empty @book.alternate_title_records.unjudged
  end

  test "rows are deleted with their book" do
    AlternateTitle.create!(titleable: @book, title: "Voyna", source: :legacy)
    AlternateTitle.create!(titleable: @other, title: "Prestuplenie", source: :legacy)
    book_id = @book.id

    @book.destroy!

    assert_equal 0, AlternateTitle.where(titleable_type: "Books::Book", titleable_id: book_id).count
    assert_equal 1, AlternateTitle.where(titleable: @other).count
  end

  test "normalize agrees with verification check" do
    ["  “Don Quixote”  ", "L\u2019Etranger", "ÉMILE"].each do |text|
      assert_equal ::Services::Books::Verification::Check.normalize(text), AlternateTitle.normalize(text)
    end
    [nil, "", "   "].each { |blank| assert_nil AlternateTitle.normalize(blank) }
  end
end
