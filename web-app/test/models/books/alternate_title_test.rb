require "test_helper"

class Books::AlternateTitleTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
    @other = books_books(:crime_and_punishment)
    Books::AlternateTitle.where(book: [@book, @other]).delete_all
  end

  test "normalized_title is set from title" do
    row = Books::AlternateTitle.create!(book: @book, title: "“Don Quixote”", source: :admin)
    assert_equal ::Services::Books::Verification::Check.normalize("“Don Quixote”"), row.normalized_title
  end

  test "one row per book and normalized title" do
    Books::AlternateTitle.create!(book: @book, title: "War and Peace", source: :legacy)
    assert_not Books::AlternateTitle.new(book: @book, title: "WAR AND PEACE", source: :legacy).valid?
    assert Books::AlternateTitle.new(book: @other, title: "WAR AND PEACE", source: :legacy).valid?
  end

  test "listed is kept and review in id order" do
    a = Books::AlternateTitle.create!(book: @book, title: "A title", source: :legacy)
    Books::AlternateTitle.create!(book: @book, title: "B title", source: :legacy, status: :removed)
    c = Books::AlternateTitle.create!(book: @book, title: "C title", source: :legacy, status: :review)
    assert_equal [a.title, c.title], @book.alternate_title_records.listed.pluck(:title)
  end

  test "unjudged is kept without a verdict" do
    unjudged = Books::AlternateTitle.create!(book: @book, title: "A title", source: :legacy)
    Books::AlternateTitle.create!(book: @book, title: "B title", source: :legacy, verdict: :same_work)
    Books::AlternateTitle.create!(book: @book, title: "C title", source: :legacy, status: :removed)
    assert_equal [unjudged], @book.alternate_title_records.unjudged.to_a
  end
end
