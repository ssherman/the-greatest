# frozen_string_literal: true

module Services
  module Books
    # Maps what a source says about nationality onto Books::Country rows, for
    # books and authors alike (spec §7). Never creates a row: the table
    # already carries junk from the legacy app's find_or_create_by!
    # ("Krakatoa", "Kaddish"), so an unknown value comes back as unmatched
    # for the caller to record.
    class CountryLookup
      Result = Struct.new(:countries, :unmatched, keyword_init: true)

      # Spellings that differ from the row Books::Country holds. The first six
      # are its own duplicate names; the rest are the countries gem's
      # nationalities (measured against our 255 rows on 2026-09-27) and the
      # two largest unmapped legacy strings.
      ALIASES = {
        "argentine" => "Argentinian", "argentinean" => "Argentinian",
        "new zealander" => "New Zealand", "persian" => "Iranian", "philippine" => "Filipino",
        "south korean" => "Korean", "saudi arabian" => "Saudi",
        "united states" => "American", "united kingdom" => "British",
        "emirian" => "Emirati", "motswana" => "Botswanan", "cape verdian" => "Cape Verdean",
        "djibouti" => "Djiboutian", "ecuadorean" => "Ecuadorian", "guinea-bissauan" => "Guinea Bissauan",
        "hong kongese" => "Hong Konger", "icelander" => "Icelandic", "kirghiz" => "Kyrgyz",
        "mosotho" => "Lesothoan", "myanmarian" => "Burmese", "maldivan" => "Maldivian",
        "slovene" => "Slovenian", "surinamer" => "Surinamese", "tadzhik" => "Tajikistani",
        "east timorese" => "Timorese", "vatican citizen" => "Vatican"
      }.freeze

      # Rows that are not nationalities.
      PLACEHOLDERS = %w[unknown multiple mulitple mixed].freeze

      # Wikidata items for states with no ISO code (or one the countries gem
      # lacks), keyed by item. Sized from 2,000 of our authors' Open Library
      # keys on 2026-09-27: 117 of 883 citizenship values had no ISO code.
      # Deliberately unmapped because the nationality is ambiguous:
      # Czechoslovakia, Cisleithania, Austrian Empire, Dutch East Indies.
      HISTORICAL = {
        "Q174193" => "British", # United Kingdom of Great Britain and Ireland
        "Q161885" => "British", # Kingdom of Great Britain
        "Q179876" => "English", # Kingdom of England
        "Q21" => "English", "Q22" => "Scottish", "Q25" => "Welsh", "Q26" => "Northern Irish",
        "Q215530" => "Irish", # Kingdom of Ireland
        "Q172579" => "Italian", # Kingdom of Italy
        "Q1747689" => "Roman", # Ancient Rome
        "Q844930" => "Greek", # Classical Athens
        "Q34266" => "Russian", # Russian Empire
        "Q2184" => "Russian", # Russian SFSR
        "Q15180" => "Soviet", # Soviet Union
        "Q28513" => "Austro-Hungarian", # Austria-Hungary
        "Q12560" => "Ottoman", # Ottoman Empire
        "Q27306" => "German", # Kingdom of Prussia
        "Q43287" => "German", # German Empire
        "Q1206012" => "German", # German Reich
        "Q41304" => "German", # Weimar Republic
        "Q7318" => "German", # Nazi Germany
        "Q713750" => "German", # West Germany
        "Q16957" => "German", # German Democratic Republic (P297 DD)
        "Q159631" => "German", # Kingdom of Württemberg
        "Q756617" => "Danish", # Kingdom of Denmark
        "Q70972" => "French", # Kingdom of France
        "Q45670" => "Portuguese", # Kingdom of Portugal
        "Q203493" => "Romanian", # Kingdom of Romania
        "Q170072" => "Dutch", # Dutch Republic
        "Q188553" => "Dutch", # Batavian Republic
        "Q129286" => "Indian", # British Raj
        "Q1775277" => "Indian", # Dominion of India
        "Q107258515" => "Iranian", # Pahlavi Iran
        "Q2526023" => "Jamaican", # Colony of Jamaica
        "Q7462" => "Chinese", "Q7313" => "Chinese", "Q9683" => "Chinese", # Song, Yuan, Tang dynasties
        "Q9903" => "Chinese", "Q8733" => "Chinese", # Ming, Qing dynasties
        "Q13426199" => "Chinese", # Republic of China (1912–1949)
        "Q191077" => "Yugoslav", # Kingdom of Yugoslavia
        "Q83286" => "Yugoslav", # SFR Yugoslavia (P297 YU)
        "Q838261" => "Yugoslav" # FR Yugoslavia (P297 YU)
      }.freeze

      def self.from_text(names) = new.from_text(names)

      def self.from_iso(codes) = new.from_iso(codes)

      def self.from_wikidata(item_ids, client: nil) = new(client: client).from_wikidata(item_ids)

      def initialize(client: nil)
        @client = client
        @rows = {}
      end

      def from_text(names)
        collect(Array(names).map { |name| name.to_s.squish }.reject(&:blank?).uniq(&:downcase)) { |name| [find(name), name] }
      end

      def from_iso(codes)
        collect(Array(codes).map { |code| code.to_s.strip.upcase }.reject(&:blank?).uniq) do |code|
          nationality = iso_nationality(code)
          [nationality && find(nationality), code]
        end
      end

      def from_wikidata(item_ids)
        ids = Array(item_ids).map(&:to_s).uniq
        rest = ids.reject { |id| HISTORICAL.key?(id) }
        codes = rest.empty? ? {} : client.country_codes(rest)
        collect(ids) do |id|
          text = HISTORICAL[id] || iso_nationality(codes.dig(id, "code"))
          [text && find(text), [id, codes.dig(id, "label")].compact.join(" ")]
        end
      end

      private

      def client
        @client ||= ::Wikidata::Client.new
      end

      # Each item yields [country or nil, how to report it when unmatched].
      def collect(items)
        countries = []
        unmatched = []
        items.each do |item|
          country, label = yield(item)
          country ? countries << country : unmatched << label
        end
        Result.new(countries: countries.uniq(&:id), unmatched: unmatched)
      end

      # "Antiguan, Barbudan" and "Bosnian, Herzegovinian": the first part names the country.
      def iso_nationality(code)
        return nil if code.blank?

        ISO3166::Country[code]&.nationality.to_s.split(",").first.to_s.strip.presence
      end

      def find(name)
        target = (ALIASES[name.downcase] || name).downcase
        return nil if PLACEHOLDERS.include?(target)
        return @rows[target] if @rows.key?(target)

        @rows[target] = ::Books::Country.where("lower(name) = ?", target).order(:id).first
      end
    end
  end
end
