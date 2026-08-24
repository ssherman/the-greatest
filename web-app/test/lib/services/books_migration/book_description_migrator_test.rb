require "test_helper"

class Services::BooksMigration::BookDescriptionMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookDescriptionMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy books row as BulkUpsertMigrator yields it: String keys, raw integer
  # use_description (0 default / 1 use_goodreads / 2 use_description).
  def legacy_book(id, overrides = {})
    {
      "id" => id,
      "ai_generated_description" => nil,
      "goodreads_description" => nil,
      "description" => nil,
      "description_source_name" => nil,
      "description_source_url" => nil,
      "use_description" => 0
    }.merge(overrides)
  end

  def descriptions_for(book)
    Description.where(describable: book).order(:source)
  end

  setup do
    @book = books_books(:of_mice_and_men)
    @other_book = books_books(:cannery_row)
  end

  test "creates one row per populated legacy column, with the right source and licence" do
    result = run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "A Goodreads blurb.",
      "description" => "A Wikipedia paragraph.",
      "description_source_name" => "wikipedia",
      "description_source_url" => "https://en.wikipedia.org/wiki/Of_Mice_and_Men")])

    assert result[:success], result[:error]
    assert_equal 3, result[:data][:count]

    ai = Description.find_by(describable: @book, source: :ai_generated)
    assert_equal "An AI summary.", ai.content
    assert_nil ai.license
    assert_nil ai.source_url

    goodreads = Description.find_by(describable: @book, source: :goodreads)
    assert_equal "A Goodreads blurb.", goodreads.content
    assert_equal "proprietary", goodreads.license
    assert_nil goodreads.source_url

    wikipedia = Description.find_by(describable: @book, source: :wikipedia)
    assert_equal "A Wikipedia paragraph.", wikipedia.content
    assert_equal "cc_by_sa_4", wikipedia.license
    assert_equal "https://en.wikipedia.org/wiki/Of_Mice_and_Men", wikipedia.source_url
    assert_nil wikipedia.source_name
  end

  test "writes summary kind, en locale, normal rank and no retrieved_at by default" do
    run_migrator([legacy_book(@book.id, "ai_generated_description" => "An AI summary.")])

    row = Description.find_by(describable: @book)
    assert_equal "summary", row.kind
    assert_equal "en", row.locale
    assert_equal "normal", row.rank
    assert_nil row.retrieved_at
    assert_nil row.source_name
  end

  test "normalises a dirty source label and keeps an unrecognised one as :other" do
    run_migrator([
      legacy_book(@book.id, "description" => "Padded label.", "description_source_name" => "Publisher "),
      legacy_book(@other_book.id, "description" => "Magazine text.", "description_source_name" => "  Publisher's Weekly  ")
    ])

    assert_equal "publisher", Description.find_by(describable: @book).source
    assert_nil Description.find_by(describable: @book).source_name

    other = Description.find_by(describable: @other_book)
    assert_equal "other", other.source
    assert_equal "Publisher's Weekly", other.source_name
  end

  test "marks only the goodreads row preferred for a use_goodreads book" do
    run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "A Goodreads blurb.",
      "use_description" => 1)])

    assert_equal "preferred", Description.find_by(describable: @book, source: :goodreads).rank
    assert_equal "normal", Description.find_by(describable: @book, source: :ai_generated).rank
  end

  # Direct behavioural guard on index_descriptions_one_preferred_per_key: with all three legacy
  # columns populated, exactly one of the three resulting rows may be `preferred`.
  test "creates exactly one preferred row, the goodreads one, when every legacy column has text" do
    result = run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "A Goodreads blurb.",
      "description" => "A Wikipedia paragraph.",
      "description_source_name" => "wikipedia",
      "use_description" => 1)])

    assert result[:success], result[:error]
    assert_equal 3, result[:data][:count]

    preferred = descriptions_for(@book).where(rank: :preferred)
    assert_equal 1, preferred.count
    assert_equal "goodreads", preferred.sole.source
  end

  test "marks only the raw-description row preferred for a use_description book" do
    run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "description" => "The editor's pick.",
      "description_source_name" => "wikipedia",
      "use_description" => 2)])

    assert_equal "preferred", Description.find_by(describable: @book, source: :wikipedia).rank
    assert_equal "normal", Description.find_by(describable: @book, source: :ai_generated).rank
  end

  # 658 of the 2,137 legacy use_goodreads books have no goodreads_description at all.
  # There is no row to mark, and legacy description_to_display falls through to the AI text,
  # which SourcePriority::ORDER already reproduces.
  test "creates no preferred row when a use_goodreads book has no goodreads text" do
    run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "",
      "use_description" => 1)])

    assert_equal 1, descriptions_for(@book).count
    assert_equal "normal", Description.find_by(describable: @book, source: :ai_generated).rank
    assert_empty Description.where(describable: @book, rank: :preferred)
  end

  test "skips nil, empty and whitespace-only legacy columns" do
    result = run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "   ",
      "goodreads_description" => "",
      "description" => nil)])

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:count]
    assert_empty descriptions_for(@book)
  end

  test "gives a blank source label an Unattributed :other row rather than guessing" do
    run_migrator([legacy_book(@book.id, "description" => "Unsourced text.", "description_source_name" => nil)])

    row = Description.find_by(describable: @book)
    assert_equal "other", row.source
    assert_equal "Unattributed", row.source_name
    assert_nil row.license
  end

  # A raw description labelled "Goodreads" must not share a conflict key with the row the
  # goodreads_description column produces. The normaliser sends it to :other.
  test "keeps a Goodreads-labelled raw description separate from the goodreads column row" do
    result = run_migrator([legacy_book(@book.id,
      "goodreads_description" => "From the Goodreads column.",
      "description" => "From the raw column, labelled Goodreads.",
      "description_source_name" => "Goodreads")])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]
    assert_equal "From the Goodreads column.", Description.find_by(describable: @book, source: :goodreads).content
    assert_equal "From the raw column, labelled Goodreads.",
      Description.find_by(describable: @book, source: :other, source_name: "Goodreads").content
  end

  test "leaves an existing row's rank and content untouched" do
    existing = Description.create!(describable: @book, kind: :summary, locale: "en",
      source: :ai_generated, content: "Hand-edited text.", rank: :preferred)

    run_migrator([legacy_book(@book.id, "ai_generated_description" => "Legacy text that must not win.")])

    existing.reload
    assert_equal "preferred", existing.rank
    assert_equal "Hand-edited text.", existing.content
  end

  test "is idempotent and reports zero inserts on a second run" do
    first = run_migrator([legacy_book(@book.id, "ai_generated_description" => "An AI summary.")])
    assert_equal 1, first[:data][:count]

    second = nil
    assert_no_difference -> { Description.count } do
      second = run_migrator([legacy_book(@book.id, "ai_generated_description" => "An AI summary.")])
    end
    assert second[:success], second[:error]
    assert_equal 0, second[:data][:count]
  end

  test "fails loud when the legacy book has no migrated Books::Book" do
    missing = ::Books::Book.maximum(:id).to_i + 999_999
    result = run_migrator([legacy_book(missing, "ai_generated_description" => "Orphan text.")])

    refute result[:success]
    assert_match(/#{missing}/, result[:error])
  end
end
