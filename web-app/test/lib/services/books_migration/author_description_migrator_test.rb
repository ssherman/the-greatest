require "test_helper"

class Services::BooksMigration::AuthorDescriptionMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::AuthorDescriptionMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy authors row as BulkUpsertMigrator yields it. Note description_source, not
  # description_source_name -- the legacy authors table names it differently to books.
  def legacy_author(id, overrides = {})
    {
      "id" => id,
      "ai_description" => nil,
      "description" => nil,
      "description_source" => nil,
      "description_source_url" => nil
    }.merge(overrides)
  end

  setup do
    @author = books_authors(:king)
    @other_author = books_authors(:bachman)
  end

  test "creates an :ai_generated row from ai_description and a :wikipedia row from description" do
    result = run_migrator([legacy_author(@author.id,
      "ai_description" => "An AI biography.",
      "description" => "A Wikipedia biography.",
      "description_source" => "wikipedia",
      "description_source_url" => "https://en.wikipedia.org/wiki/Stephen_King")])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    ai = Description.find_by(describable: @author, source: :ai_generated)
    assert_equal "An AI biography.", ai.content
    assert_nil ai.license
    assert_nil ai.source_url

    wikipedia = Description.find_by(describable: @author, source: :wikipedia)
    assert_equal "A Wikipedia biography.", wikipedia.content
    assert_equal "cc_by_sa_4", wikipedia.license
    assert_equal "https://en.wikipedia.org/wiki/Stephen_King", wikipedia.source_url
  end

  test "writes summary kind, en locale and normal rank, and never a preferred row" do
    run_migrator([legacy_author(@author.id,
      "ai_description" => "An AI biography.",
      "description" => "A Wikipedia biography.",
      "description_source" => "wikipedia")])

    Description.where(describable: @author).each do |row|
      assert_equal "summary", row.kind
      assert_equal "en", row.locale
      assert_equal "normal", row.rank
      assert_nil row.retrieved_at
    end
    assert_empty Description.where(describable: @author, rank: :preferred)
  end

  # 452 of the 8,670 legacy author descriptions state no source and carry no source_url.
  # Asserting cc_by_sa_4 on them would be an attribution the app cannot honour (D10).
  test "gives an author description with no stated source an Unattributed :other row" do
    run_migrator([legacy_author(@author.id,
      "description" => "A biography of unknown origin.",
      "description_source" => nil)])

    row = Description.find_by(describable: @author)
    assert_equal "other", row.source
    assert_equal "Unattributed", row.source_name
    assert_nil row.license
    assert_nil row.source_url
  end

  test "normalises a dirty wikipedia label however it is cased or padded" do
    run_migrator([
      legacy_author(@author.id, "description" => "One.", "description_source" => "Wikipedia "),
      legacy_author(@other_author.id, "description" => "Two.", "description_source" => "wikipedia")
    ])

    assert_equal "wikipedia", Description.find_by(describable: @author).source
    assert_equal "wikipedia", Description.find_by(describable: @other_author).source
  end

  test "skips nil, empty and whitespace-only legacy columns" do
    result = run_migrator([legacy_author(@author.id, "ai_description" => "  ", "description" => "")])

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:count]
    assert_empty Description.where(describable: @author)
  end

  test "leaves an existing row's rank and content untouched" do
    existing = Description.create!(describable: @author, kind: :summary, locale: "en",
      source: :ai_generated, content: "Hand-edited text.", rank: :preferred)

    run_migrator([legacy_author(@author.id, "ai_description" => "Legacy text that must not win.")])

    existing.reload
    assert_equal "preferred", existing.rank
    assert_equal "Hand-edited text.", existing.content
  end

  test "is idempotent and reports zero inserts on a second run" do
    first = run_migrator([legacy_author(@author.id, "ai_description" => "An AI biography.")])
    assert_equal 1, first[:data][:count]

    second = nil
    assert_no_difference -> { Description.count } do
      second = run_migrator([legacy_author(@author.id, "ai_description" => "An AI biography.")])
    end
    assert second[:success], second[:error]
    assert_equal 0, second[:data][:count]
  end

  test "fails loud when the legacy author has no migrated Books::Author" do
    missing = Books::Author.maximum(:id).to_i + 999_999
    result = run_migrator([legacy_author(missing, "ai_description" => "Orphan text.")])

    refute result[:success]
    assert_match(/#{missing}/, result[:error])
  end
end
