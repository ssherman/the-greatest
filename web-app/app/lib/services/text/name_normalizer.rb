module Services
  module Text
    # Folds the Unicode variety of "a space" and of composed characters down
    # to one form, so two renderings of the same name or title compare equal.
    # 128 duplicate author groups in the books data came from a U+202F
    # narrow no-break space that an exact-string lookup could not see.
    class NameNormalizer
      # Every Unicode space separator (Zs), plus the zero-width space, the
      # word joiner and the byte-order mark, which are invisible and never
      # meaningful inside a name.
      SPACES = /[\p{Zs}​⁠﻿]+/

      def self.call(text)
        return nil if text.nil?
        return "" if text.empty?

        text.unicode_normalize(:nfkc).gsub(SPACES, " ").squeeze(" ").strip
      end
    end
  end
end
