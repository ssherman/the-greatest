# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::AuthorCountryMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    migrator = Services::BooksMigration::AuthorCountryMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  def country(name) = ::Books::Country.find_by(name: name) || ::Books::Country.create!(name: name)

  def countries_of(author) = author.reload.countries.pluck(:name).sort

  test "links an author to the country its nationality names" do
    country("Russian")
    tolstoy = books_authors(:tolstoy)

    result = run_migrator([{"id" => tolstoy.id, "nationality_text" => "Russian"}])

    assert result[:success], result[:error]
    assert_equal "Books::AuthorCountry", result[:data][:model]
    assert_equal ["Russian"], countries_of(tolstoy)
  end

  test "splits compounds on hyphens and slashes" do
    country("Russian")
    country("American")
    country("French")
    king = books_authors(:king)
    garnett = books_authors(:garnett)

    run_migrator([
      {"id" => king.id, "nationality_text" => "Russian-American"},
      {"id" => garnett.id, "nationality_text" => "French/American"}
    ])

    assert_equal ["American", "Russian"], countries_of(king)
    assert_equal ["American", "French"], countries_of(garnett)
  end

  test "keeps Austro-Hungarian whole, even inside a compound" do
    country("Austro-Hungarian")
    country("American")
    king = books_authors(:king)

    result = run_migrator([{"id" => king.id, "nationality_text" => "Austro-Hungarian-American"}])

    assert_equal ["American", "Austro-Hungarian"], countries_of(king)
    assert_empty result[:data][:unmapped]
  end

  test "maps aliases through the country lookup" do
    country("Argentinian")
    king = books_authors(:king)

    run_migrator([{"id" => king.id, "nationality_text" => "Argentine"}])

    assert_equal ["Argentinian"], countries_of(king)
  end

  test "reports unmapped strings with their author counts, largest first, and never creates a country" do
    country("Russian")
    rows = [
      {"id" => books_authors(:king).id, "nationality_text" => "Martian"},
      {"id" => books_authors(:garnett).id, "nationality_text" => "Martian"},
      {"id" => books_authors(:tolstoy).id, "nationality_text" => "Russian-Venusian"}
    ]

    result = assert_no_difference(-> { ::Books::Country.count }) { run_migrator(rows) }

    assert_equal({"Martian" => 2, "Venusian" => 1}, result[:data][:unmapped])
    assert_equal [["Martian", 2], ["Venusian", 1]], result[:data][:unmapped].to_a
  end

  test "sorts unmapped by count even when a smaller count is seen first" do
    rows = [
      {"id" => books_authors(:tolstoy).id, "nationality_text" => "Venusian"},
      {"id" => books_authors(:king).id, "nationality_text" => "Martian"},
      {"id" => books_authors(:garnett).id, "nationality_text" => "Martian"}
    ]

    result = run_migrator(rows)

    assert_equal [["Martian", 2], ["Venusian", 1]], result[:data][:unmapped].to_a
  end

  test "skips a legacy author that no longer exists and counts it" do
    country("Russian")

    result = run_migrator([{"id" => 999_999_999, "nationality_text" => "Russian"}])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:missing_authors]
    assert_equal 0, ::Books::AuthorCountry.count
  end

  test "dedupes two parts of one nationality that resolve to the same country" do
    country("American")
    king = books_authors(:king)

    result = run_migrator([{"id" => king.id, "nationality_text" => "American-United States"}])

    assert result[:success], result[:error]
    assert_equal 1, ::Books::AuthorCountry.where(author_id: king.id).count
    assert_equal 1, result[:data][:count]
  end

  test "is idempotent" do
    country("Russian")
    rows = [{"id" => books_authors(:tolstoy).id, "nationality_text" => "Russian"}]
    run_migrator(rows)

    assert_no_difference(-> { ::Books::AuthorCountry.count }) { run_migrator(rows) }
  end

  test "sync mode maps the run's authors only" do
    country("Russian")
    in_run = ::Books::Author.create!(name: "In The Run")
    outside = ::Books::Author.create!(name: "Outside")
    m = Services::BooksMigration::AuthorCountryMigrator.new(sync: sync_scope(author_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => in_run.id, "nationality_text" => "Russian"}],
      [{"id" => outside.id, "nationality_text" => "Russian"}]
    )

    m.call

    assert ::Books::AuthorCountry.exists?(author_id: in_run.id)
    refute ::Books::AuthorCountry.exists?(author_id: outside.id)
  end
end
