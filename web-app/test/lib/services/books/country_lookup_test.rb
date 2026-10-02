# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class CountryLookupTest < ActiveSupport::TestCase
      def country(name) = ::Books::Country.find_by(name: name) || ::Books::Country.create!(name: name)

      test "from_text matches names case-insensitively and reports the rest" do
        french = books_countries(:french)

        result = CountryLookup.from_text(["french", "Martian", " French "])

        assert_equal [french], result.countries
        assert_equal ["Martian"], result.unmatched
      end

      test "from_text maps the duplicate spellings Books::Country already holds" do
        argentinian = country("Argentinian")
        new_zealand = country("New Zealand")
        korean = country("Korean")

        result = CountryLookup.from_text(["Argentine", "New Zealander", "South Korean"])

        assert_equal [argentinian, new_zealand, korean], result.countries
      end

      test "from_text never matches a placeholder row" do
        country("Multiple")

        result = CountryLookup.from_text(["Unknown", "Multiple"])

        assert_empty result.countries
        assert_equal ["Unknown", "Multiple"], result.unmatched
      end

      test "from_text never creates a country" do
        assert_no_difference -> { ::Books::Country.count } do
          CountryLookup.from_text(["Atlantean", "Krakatoan"])
        end
      end

      test "from_iso goes through the countries gem's nationality" do
        french = books_countries(:french)
        argentinian = country("Argentinian")
        bosnian = country("Bosnian")

        result = CountryLookup.from_iso(["fr", "AR", "BA", "ZZ"])

        assert_equal [french, argentinian, bosnian], result.countries
        assert_equal ["ZZ"], result.unmatched
      end

      test "from_wikidata uses the historical map first, without calling Wikidata for those items" do
        russian = country("Russian")
        client = mock("wikidata")
        client.expects(:country_codes).never

        result = CountryLookup.from_wikidata(["Q34266"], client: client)

        assert_equal [russian], result.countries
      end

      test "from_wikidata maps an item's ISO code, and reports an item it cannot place" do
        french = books_countries(:french)
        client = mock("wikidata")
        client.expects(:country_codes).with(["Q142", "Q33946"]).returns(
          "Q142" => {"code" => "FR", "label" => "France"},
          "Q33946" => {"code" => nil, "label" => "Czechoslovakia"}
        )

        result = CountryLookup.from_wikidata(["Q142", "Q33946"], client: client)

        assert_equal [french], result.countries
        assert_equal ["Q33946 Czechoslovakia"], result.unmatched
      end

      test "the historical map wins over an ISO code the countries gem does not know" do
        german = country("German")
        client = mock("wikidata")
        client.expects(:country_codes).never

        assert_equal [german], CountryLookup.from_wikidata(["Q16957"], client: client).countries
      end

      test "two items for one nationality give one country" do
        british = country("British")
        client = mock("wikidata")
        client.expects(:country_codes).with(["Q145"]).returns("Q145" => {"code" => "GB", "label" => "United Kingdom"})

        assert_equal [british], CountryLookup.from_wikidata(["Q145", "Q174193"], client: client).countries
      end
    end
  end
end
