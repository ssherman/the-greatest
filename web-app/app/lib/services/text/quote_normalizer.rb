module Services
  module Text
    class QuoteNormalizer
      LEFT_SINGLE_QUOTE = "\u2018"
      RIGHT_SINGLE_QUOTE = "\u2019"
      LEFT_DOUBLE_QUOTE = "\u201C"
      RIGHT_DOUBLE_QUOTE = "\u201D"
      STRAIGHT_APOSTROPHE = "\u0027"
      STRAIGHT_QUOTE = "\u0022"

      def self.call(text)
        return nil if text.nil?
        return "" if text.empty?

        text
          .gsub(LEFT_SINGLE_QUOTE, STRAIGHT_APOSTROPHE)
          .gsub(RIGHT_SINGLE_QUOTE, STRAIGHT_APOSTROPHE)
          .gsub(LEFT_DOUBLE_QUOTE, STRAIGHT_QUOTE)
          .gsub(RIGHT_DOUBLE_QUOTE, STRAIGHT_QUOTE)
      end
    end
  end
end
