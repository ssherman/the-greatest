# frozen_string_literal: true

module Services
  module Games
    # Converts IGDB numeric country codes (ISO 3166-1 numeric) to ISO 3166-1 alpha-2
    class CountryCodeConverter
      # IGDB uses ISO 3166-1 numeric codes
      # Map to ISO 3166-1 alpha-2 (2-letter codes)
      # Full list: https://en.wikipedia.org/wiki/ISO_3166-1_numeric
      COUNTRY_MAP = {
        840 => "US", # United States
        392 => "JP", # Japan
        826 => "GB", # United Kingdom
        124 => "CA", # Canada
        250 => "FR", # France
        276 => "DE", # Germany
        380 => "IT", # Italy
        724 => "ES", # Spain
        528 => "NL", # Netherlands
        752 => "SE", # Sweden
        616 => "PL", # Poland
        203 => "CZ", # Czech Republic
        643 => "RU", # Russia
        156 => "CN", # China
        410 => "KR", # South Korea
        158 => "TW", # Taiwan
        0o36 => "AU", # Australia
        0o76 => "BR", # Brazil
        484 => "MX", # Mexico
        0o32 => "AR", # Argentina
        0o56 => "BE", # Belgium
        0o40 => "AT", # Austria
        756 => "CH", # Switzerland
        208 => "DK", # Denmark
        246 => "FI", # Finland
        578 => "NO", # Norway
        372 => "IE", # Ireland
        620 => "PT", # Portugal
        792 => "TR", # Turkey
        356 => "IN", # India
        702 => "SG", # Singapore
        554 => "NZ", # New Zealand
        804 => "UA", # Ukraine
        348 => "HU", # Hungary
        300 => "GR", # Greece
        784 => "AE"  # United Arab Emirates
      }.freeze

      def self.igdb_to_iso(igdb_code)
        return nil if igdb_code.blank?
        COUNTRY_MAP[igdb_code.to_i]
      end
    end
  end
end
