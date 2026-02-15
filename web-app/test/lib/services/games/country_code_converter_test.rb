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

      # Regression tests for octal literal bug - these codes must use decimal values
      test "converts Australia numeric code 36 to ISO alpha-2" do
        assert_equal "AU", CountryCodeConverter.igdb_to_iso(36)
      end

      test "converts Brazil numeric code 76 to ISO alpha-2" do
        assert_equal "BR", CountryCodeConverter.igdb_to_iso(76)
      end

      test "converts Argentina numeric code 32 to ISO alpha-2" do
        assert_equal "AR", CountryCodeConverter.igdb_to_iso(32)
      end

      test "converts Belgium numeric code 56 to ISO alpha-2" do
        assert_equal "BE", CountryCodeConverter.igdb_to_iso(56)
      end

      test "converts Austria numeric code 40 to ISO alpha-2" do
        assert_equal "AT", CountryCodeConverter.igdb_to_iso(40)
      end
    end
  end
end
