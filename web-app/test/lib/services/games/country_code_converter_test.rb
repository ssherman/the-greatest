# frozen_string_literal: true

require "test_helper"

module Services
  module Games
    class CountryCodeConverterTest < ActiveSupport::TestCase
      test "converts US numeric code to ISO alpha-2" do
        assert_equal "US", CountryCodeConverter.igdb_to_iso(840)
      end

      test "converts Japan numeric code to ISO alpha-2" do
        assert_equal "JP", CountryCodeConverter.igdb_to_iso(392)
      end

      test "converts UK numeric code to ISO alpha-2" do
        assert_equal "GB", CountryCodeConverter.igdb_to_iso(826)
      end

      test "returns nil for unknown country code" do
        assert_nil CountryCodeConverter.igdb_to_iso(999)
      end

      test "returns nil for blank input" do
        assert_nil CountryCodeConverter.igdb_to_iso(nil)
        assert_nil CountryCodeConverter.igdb_to_iso("")
      end

      test "handles string input by converting to integer" do
        assert_equal "US", CountryCodeConverter.igdb_to_iso("840")
      end
    end
  end
end
