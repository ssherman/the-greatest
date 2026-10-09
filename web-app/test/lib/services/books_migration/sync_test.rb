require "test_helper"

class Services::BooksMigration::SyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  # The user-data steps run in every test here, and three of them move sequences.
  isolate_sequences "reviews", "saved_searches", "corrections"

  SYNC_MIGRATORS = %w[
    LanguageMigrator AuthorMigrator BookMigrator BookAuthorMigrator EditionMigrator BookIdentifierMigrator
    BookWorkIdentifierMigrator AuthorIdentifierMigrator EditionIdentifierMigrator EditionIsbnIdentifierMigrator
    CategoryMigrator CategoryItemMigrator BookAttributesMigrator BookTypeCategoryMigrator CountryMigrator
    AuthorCountryMigrator BookCountryMigrator ExternalLinkMigrator BookDescriptionMigrator
    AuthorDescriptionMigrator BookImageMigrator UserListMigrator SavedSearchMigrator ReviewMigrator
    CorrectionMigrator
  ].freeze

  setup do
    @old = 3.days.ago
    @recent = 1.hour.ago
    init_watermarks(books: 1_000, authors: 500, book_identifiers: 5_000)
    @existing = ::Books::Book.create!(id: 900, title: "Cleaned Here")
    map_book_type_categories
    Services::BooksMigration::UserMigrator.stubs(:call).returns(success: true, data: {model: "User", count: 0})
    Services::BooksMigration::NewsPostMigrator.stubs(:call).returns(
      Services::BooksMigration::NewsPostMigrator::Result.new(success?: true, data: {}, errors: [])
    )
    Services::BooksMigration::ReadingGoalMigrator.stubs(:call).returns(success: true, data: {model: "Books::ReadingGoal", count: 0})
    Services::BooksMigration::RecommendationConfigMigrator.stubs(:call).returns(success: true, data: {model: "Books::RecommendationConfig", count: 0})
    Services::BooksMigration::UserListItemMigrator.any_instance.stubs(:legacy_items_for).returns([])
    Services::BooksMigration::UserListItemMigrator.any_instance.stubs(:legacy_item_count).returns(0)
    stub_legacy(
      "AuthorMigrator" => [{"id" => 501, "name" => "New Legacy Author", "family_name" => "Author", "alternative_names" => nil}],
      "BookMigrator" => [
        {"id" => 900, "title" => "Legacy Title", "original_language_id" => nil},
        {"id" => 1_001, "title" => "New Legacy Book", "original_language_id" => nil},
        {"id" => 1_002, "title" => "Too Fresh", "original_language_id" => nil}
      ],
      "BookAuthorMigrator" => [{"id" => 1, "book_id" => 1_001, "author_id" => 501, "position" => 1}],
      "EditionMigrator" => [
        {"id" => 7_001, "book_id" => 1_001, "title" => "HC", "publication_year" => 2026, "popularity" => 1, "book_binding" => 1, "metadata" => {}},
        {"id" => 7_002, "book_id" => 900, "title" => "Late Edition", "publication_year" => 2026, "popularity" => 1, "book_binding" => 1, "metadata" => {}}
      ],
      "BookIdentifierMigrator" => [{"id" => 5_001, "book_id" => 900, "identifier_type" => 5, "identifier" => "424242"}]
    )
  end

  def legacy
    FakeLegacySource.new(
      book_rows: [[1_001, @old], [1_002, @recent]],
      author_rows: [[501, @old]],
      book_identifier_rows: [[5_001, @old]],
      book_ids: [900, 1_001, 1_002],
      author_ids: [501]
    )
  end

  def stub_legacy(rows)
    SYNC_MIGRATORS.each do |name|
      stub = Services::BooksMigration.const_get(name).any_instance.stubs(:legacy_each)
      stub.multiple_yields(*rows[name].zip) if rows[name]
    end
  end

  def map_book_type_categories
    Services::BooksMigration::BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS.each_value do |legacy_id|
      category = ::Books::Category.create!(name: "Type #{legacy_id}", category_type: :genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
    end
  end

  def watermarks = LegacySyncWatermark.pluck(:key, :value).to_h

  test "brings over a new legacy book with its author and edition, and nothing for a book already here but its new identifier" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert_equal "New Legacy Book", ::Books::Book.find(1_001).title
    assert ::Books::BookAuthor.exists?(book_id: 1_001, author_id: 501)
    assert_equal 1_001, ::Books::Edition.find(LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 7_001)).book_id
    assert_equal "Cleaned Here", @existing.reload.title
    assert_nil LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 7_002)
    assert Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: 900, value: "424242")
    refute ::Books::Book.exists?(1_002)
  end

  test "advances the watermarks to the last rows it processed" do
    Services::BooksMigration::Sync.call(legacy: legacy)

    assert_equal({"books" => 1_001, "authors" => 501, "book_identifiers" => 5_001}, watermarks)
  end

  # updated_at marks the last successful sync (CategoryMigrator's retry repair reads
  # it), so it must move even when no watermark value does.
  test "a successful run stamps the watermarks even when nothing is new" do
    LegacySyncWatermark.update_all(updated_at: 1.day.ago)
    quiet = FakeLegacySource.new(book_ids: [900], author_ids: [])
    stub_legacy({})

    Services::BooksMigration::Sync.call(legacy: quiet)

    assert_operator LegacySyncWatermark.minimum(:updated_at), :>, 1.minute.ago
  end

  test "FINAL takes the book still inside the delay" do
    Services::BooksMigration::Sync.call(final: true, legacy: legacy)

    assert ::Books::Book.exists?(1_002)
    assert_equal 1_002, watermarks["books"]
  end

  test "queues search indexing for the books and authors it inserted only" do
    # The setup's create of book 900 queued its own request; the sync must add none.
    result = assert_no_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: 900).count } do
      Services::BooksMigration::Sync.call(legacy: legacy)
    end

    assert SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 1_001, action: :index_item)
    assert SearchIndexRequest.exists?(parent_type: "Books::Author", parent_id: 501, action: :index_item)
    assert_equal({"Books::Book" => 1, "Books::Author" => 1}, result.data[:indexed])
  end

  test "a merged or deleted book is not brought back" do
    RecordRedirect.create!(item_type: "Books::Book", from_id: 1_001, to_id: 900)

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    refute ::Books::Book.exists?(1_001)
    assert_equal 1_001, watermarks["books"]
  end

  test "a failed step leaves the watermarks and queues no indexing" do
    Services::BooksMigration::EditionMigrator.stubs(:call).returns(success: false, error: "boom", data: {})

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_match(/editions failed: boom/, result.errors.first)
    assert_equal({"books" => 1_000, "authors" => 500, "book_identifiers" => 5_000}, watermarks)
    refute SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 1_001)
  end

  test "a step that raises fails the run without moving the watermarks" do
    Services::BooksMigration::NewsPostMigrator.stubs(:call).raises(RuntimeError, "legacy gone")

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_match(/news_posts raised: legacy gone/, result.errors.first)
    assert_equal 1_000, watermarks["books"]
  end

  test "a retry after a failed run finishes the books that run inserted" do
    Services::BooksMigration::EditionMigrator.stubs(:call).returns(success: false, error: "boom", data: {})
    Services::BooksMigration::Sync.call(legacy: legacy)
    assert ::Books::Book.exists?(1_001)
    Services::BooksMigration::EditionMigrator.unstub(:call)

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 7_001)
    assert_equal 1, ::Books::BookAuthor.where(book_id: 1_001).count
    assert SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 1_001, action: :index_item)
    assert_equal 1_001, watermarks["books"]
  end

  test "refuses to run before sync_init" do
    LegacySyncWatermark.delete_all
    Services::BooksMigration::BookMigrator.expects(:call).never

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_match(/sync_init/, result.errors.first)
  end

  test "the report's would-insert numbers equal what the sync inserts" do
    plan = Services::BooksMigration::SyncPlan.build(legacy: legacy)

    assert_difference -> { ::Books::Book.count } => plan.report[:books][:would_insert],
      -> { ::Books::Author.count } => plan.report[:authors][:would_insert] do
      Services::BooksMigration::Sync.call(legacy: legacy)
    end
    assert_equal 1, plan.report[:books][:would_insert]
  end

  test "runs the user-data steps after the catalog, in :all's order" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert_equal %w[book_images user_lists user_list_items reading_goals saved_searches recommendation_configs reviews review_summaries corrections],
      result.data[:steps].map(&:first).last(9)
  end

  test "carries a list item on a book the run brought over and waits on one still inside the delay" do
    user = users(:regular_user)
    ::Books::UserList.create!(id: 700, user: user, name: "Legacy", list_type: :custom)
    Services::BooksMigration::UserListMigrator.any_instance.stubs(:legacy_each).multiple_yields([{
      "id" => 700, "user_id" => user.id, "name" => "Legacy", "description" => nil, "list_type" => 4,
      "view_mode" => nil, "public" => true, "position" => 1, "created_at" => @old, "updated_at" => @old
    }])
    item = ->(id, book_id, position) {
      {"id" => id, "user_list_id" => 700, "book_id" => book_id, "position" => position, "read_date" => nil,
       "created_at" => @old, "updated_at" => @old}
    }
    Services::BooksMigration::UserListItemMigrator.any_instance.stubs(:legacy_items_for)
      .returns([item.call(1, 1_001, 1), item.call(2, 1_002, 2)])

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert_equal [1_001], UserListItem.where(user_list_id: 700).pluck(:listable_id)
    items_outcome = result.data[:steps].to_h["user_list_items"]
    assert_equal 1, items_outcome[:data][:waiting]
  end

  test "a failed user-data step leaves the watermarks" do
    Services::BooksMigration::ReviewMigrator.stubs(:call).returns(success: false, error: "boom", data: {})

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_includes result.errors.first, "reviews failed: boom"
    assert_equal({"books" => 1_000, "authors" => 500, "book_identifiers" => 5_000}, watermarks)
  end
end
