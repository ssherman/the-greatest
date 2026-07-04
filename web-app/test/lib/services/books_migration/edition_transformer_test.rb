require "test_helper"

class Services::BooksMigration::EditionTransformerTest < ActiveSupport::TestCase
  def transform(overrides = {})
    Services::BooksMigration::EditionTransformer.call({
      "title" => "First Edition", "publication_year" => 1937,
      "popularity" => 42, "book_binding" => 1, "metadata" => {"src" => "x"}
    }.merge(overrides))
  end

  test "maps core fields directly" do
    attrs = transform
    assert_equal "First Edition", attrs[:title]
    assert_equal 1937, attrs[:publication_year]
    assert_equal 42, attrs[:popularity]
    assert_equal({"src" => "x"}, attrs[:metadata])
  end

  test "does not emit edition_type, book_id, or language_id" do
    attrs = transform
    refute attrs.key?(:edition_type)
    refute attrs.key?(:book_id)
    refute attrs.key?(:language_id)
  end

  test "re-encodes each legacy book_binding to the new symbol by name" do
    {0 => :paperback, 1 => :hardcover, 2 => :ebook, 3 => :audiobook,
     4 => :mass_market, 5 => :audiobook, 6 => :library_binding,
     7 => :other, 8 => :leather_bound, 9 => :other}.each do |legacy_int, new_sym|
      assert_equal new_sym, transform("book_binding" => legacy_int)[:book_binding],
        "legacy binding #{legacy_int} should map to #{new_sym}"
    end
  end

  test "nil book_binding stays nil" do
    assert_nil transform("book_binding" => nil)[:book_binding]
  end

  test "unknown book_binding raises" do
    assert_raises(RuntimeError) { transform("book_binding" => 99) }
  end

  test "nil metadata becomes an empty hash (column is NOT NULL)" do
    assert_equal({}, transform("metadata" => nil)[:metadata])
  end

  test "extracts publisher_name from the amazon ByLineInfo manufacturer path" do
    md = {"amazon" => {"ItemInfo" => {"ByLineInfo" => {"Manufacturer" => {"DisplayValue" => "Random House"}}}}}
    assert_equal "Random House", transform("metadata" => md)[:publisher_name]
  end

  test "publisher_name is nil when the manufacturer path is absent, blank, or metadata is nil" do
    assert_nil transform("metadata" => {"amazon" => {"ItemInfo" => {}}})[:publisher_name]
    blank = {"amazon" => {"ItemInfo" => {"ByLineInfo" => {"Manufacturer" => {"DisplayValue" => ""}}}}}
    assert_nil transform("metadata" => blank)[:publisher_name]
    assert_nil transform("metadata" => nil)[:publisher_name]
  end
end
