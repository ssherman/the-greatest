module Services
  module Text
    # Folds a name or title to the key its spellings share: case and
    # diacritics dropped ("García" is "garcia"), and the letters Unicode
    # does not compose from a base letter and a mark transliterated the way
    # plain-Latin labels spell them. NFD alone leaves "Stanisław" and
    # "Stanislaw" different.
    class NameFolder
      LETTERS = {
        "ł" => "l", "ø" => "o", "æ" => "ae", "œ" => "oe", "ß" => "ss",
        "đ" => "d", "ð" => "d", "þ" => "th", "ı" => "i"
      }.freeze
      PATTERN = Regexp.union(LETTERS.keys)

      def self.call(text)
        text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(PATTERN, LETTERS)
      end
    end
  end
end
