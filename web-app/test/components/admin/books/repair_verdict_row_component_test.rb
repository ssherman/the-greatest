# frozen_string_literal: true

require "test_helper"

class Admin::Books::RepairVerdictRowComponentTest < ViewComponent::TestCase
  setup do
    @source = books_books(:war_and_peace)
    @target = books_books(:got)
    @books = ::Books::Book.where(id: [@source.id, @target.id]).includes(:authors).index_by(&:id)
  end

  def build(kind, payload)
    ::Books::RepairVerdict.new(id: 77, kind: kind, subject_key: "k", decided_by: :rule, payload: payload)
  end

  def text_of(verdict, **lookups)
    render_inline(Admin::Books::RepairVerdictRowComponent.new(verdict: verdict, books: @books, **lookups)).text.squish
  end

  test "merge_books shows both books, the target's list count and the Goodreads export title" do
    verdict = build(:merge_books, {"source_id" => @source.id, "target_id" => @target.id,
                                   "full_title" => "The Export Title", "author_names" => ["Ann Author", "Bo Author"]})

    text = text_of(verdict, list_counts: {@target.id => 3})

    assert_includes text, @source.title
    assert_includes text, @target.title
    assert_includes text, "on 3 lists"
    assert_includes text, "Goodreads export: \"The Export Title\" by Ann Author, Bo Author"
  end

  test "merge_books omits the list count and export line when there is nothing to say" do
    text = text_of(build(:merge_books, {"source_id" => @source.id, "target_id" => @target.id}))

    assert_not_includes text, " lists"
    assert_not_includes text, "Goodreads export"
  end

  test "a gone book shows (gone)" do
    text = text_of(build(:merge_books, {"source_id" => @source.id, "target_id" => 999_999_999}))

    assert_includes text, "#999999999 (gone)"
    assert_includes text, @source.title
  end

  test "fix_identity shows the current title and the payload title" do
    verdict = build(:fix_identity, {"book_id" => @source.id, "full_title" => "Made to Stick: Why", "author_names" => ["Chip Heath"]})

    text = text_of(verdict)

    assert_includes text, @source.title
    assert_includes text, "\"Made to Stick: Why\" by Chip Heath"
  end

  test "merge_authors shows the name and a gone author" do
    author = books_authors(:tolstoy)
    verdict = build(:merge_authors, {"source_id" => author.id, "target_id" => 999_999_999})

    text = render_inline(Admin::Books::RepairVerdictRowComponent.new(verdict: verdict, authors: {author.id => author})).text.squish

    assert_includes text, author.name
    assert_includes text, "#999999999 (gone)"
  end

  test "strip_identifier keeps the summary and adds the book's title" do
    verdict = build(:strip_identifier, {"book_id" => @source.id, "remove" => [["isbn13", "9780000000002"]]})

    text = text_of(verdict)

    assert_includes text, verdict.summary
    assert_includes text, "\"#{@source.title}\""
  end
end
