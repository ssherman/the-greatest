require "test_helper"

class Services::BooksMigration::DescriptionSourceNormalizerTest < ActiveSupport::TestCase
  def normalize(label)
    Services::BooksMigration::DescriptionSourceNormalizer.call(label)
  end

  test "maps wikipedia to :wikipedia with a CC BY-SA licence, however it is cased or padded" do
    ["wikipedia", "Wikipedia", "WIkipedia", "Wikipedia ", " wikipedia"].each do |label|
      assert_equal({source: :wikipedia, source_name: nil, license: :cc_by_sa_4}, normalize(label),
        "expected #{label.inspect} to normalise to :wikipedia")
    end
  end

  test "maps openlibrary to :openlibrary with CC0" do
    assert_equal({source: :openlibrary, source_name: nil, license: :cc0}, normalize("OpenLibrary"))
  end

  test "maps publisher to :publisher with no licence, trailing space and all" do
    ["Publisher", "Publisher "].each do |label|
      assert_equal({source: :publisher, source_name: nil, license: nil}, normalize(label))
    end
  end

  test "collapses both Google spellings onto one :other label" do
    ["Google", "google", "Google Books"].each do |label|
      assert_equal({source: :other, source_name: "Google Books", license: nil}, normalize(label))
    end
  end

  test "maps a blank label to :other Unattributed rather than guessing a source" do
    [nil, "", "   "].each do |label|
      assert_equal({source: :other, source_name: "Unattributed", license: nil}, normalize(label),
        "expected #{label.inspect} to normalise to Unattributed")
    end
  end

  test "maps a non-breaking-space label to :other Unattributed, since strip only removes ASCII whitespace" do
    label = " "
    assert_equal({source: :other, source_name: "Unattributed", license: nil}, normalize(label),
      "expected #{label.inspect} to normalise to Unattributed")
  end

  test "keeps an unrecognised label as :other with its case preserved and whitespace stripped" do
    assert_equal({source: :other, source_name: "Amazon.com", license: nil}, normalize("Amazon.com"))
    assert_equal({source: :other, source_name: "Publisher's Weekly", license: nil}, normalize("  Publisher's Weekly  "))
    assert_equal({source: :other, source_name: "WIkpedia", license: nil}, normalize("WIkpedia"))
  end

  test "never returns :ai_generated or :goodreads, so a normalised row cannot collide with a column row" do
    ["Goodreads", "good reads", "AI", "wikipedia", ""].each do |label|
      assert_not_includes [:ai_generated, :goodreads], normalize(label)[:source],
        "#{label.inspect} must not normalise onto a source another column already claims"
    end
  end

  test "returns a source_name if and only if the source is :other" do
    ["wikipedia", "OpenLibrary", "Publisher"].each do |label|
      assert_nil normalize(label)[:source_name]
    end
    ["Google", "", "Amazon.com"].each do |label|
      assert_not_nil normalize(label)[:source_name]
      assert_equal :other, normalize(label)[:source]
    end
  end
end
