module Services
  module Text
    # The comparison key for a person's name: the finder's normalization
    # (quotes, Unicode spaces, NFKC, case), plus single-letter initials
    # folded, so "J.D. Salinger", "J. D. Salinger" and "J D Salinger" are one
    # name. Measured on the development authors (2026-10-09), the fold joined
    # 212 authors in 64 groups, all the same person, and nothing else.
    #
    # Only a single letter followed by a full stop is folded. Every other word
    # must still match: "Jr." and "JR" stay apart, "JD" is not "J. D.", and a
    # surname alone is never a name. The legacy books app matched on surnames
    # and produced many wrong authors; this key exists so nothing has to.
    class PersonNameKey
      # A letter with no letter before it, followed by a full stop.
      INITIAL = /(?<!\p{L})(\p{L})\./

      def self.call(text)
        return nil if text.nil?

        NameNormalizer.call(QuoteNormalizer.call(text.to_s)).downcase
          .gsub(INITIAL, '\1 ')
          .squeeze(" ").strip
          .presence
      end

      def self.all(names)
        Array(names).filter_map { |name| call(name) }.uniq
      end
    end
  end
end
