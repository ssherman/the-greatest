# frozen_string_literal: true

module Services
  module Books
    # Deterministic guard on an AI description before it is written. The
    # prompt forbids all of this and the review task looks for it; this is
    # the part a regex can prove. Word bounds are looser than the prompt's
    # 60 to 110 on purpose: they catch runaways, not the target.
    #
    # Whether the text names the book's title or author is deliberately NOT
    # checked here. A string match cannot tell the title "Emma" from the
    # character Emma, or "Night" from the noun, and 17k books have one-word
    # titles; that judgment belongs to the review task's names_title and
    # names_author codes.
    class DescriptionCheck
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # "([label](https://url))", the shape the model pastes in despite the
      # rules. The URLs are already in the run's citations. The URL segment
      # allows one level of balanced parens, since a Wikipedia disambiguation
      # URL such as .../Foo_(novel) is a likely citation target.
      MARKDOWN_CITATION = /\s*\(\[[^\]]*\]\((?:[^()\s]|\([^()\s]*\))*\)\)/
      MIN_WORDS = 40
      MAX_WORDS = 140

      def self.call(text)
        cleaned = text.to_s.gsub(MARKDOWN_CITATION, "").strip
        errors = []
        # An em dash is always flagged. An en dash only counts as the same
        # violation when it is being used as a dash (spaced on at least one
        # side) rather than as a hyphen in a year range like "1939-1945".
        errors << "em_dash" if cleaned.include?("—") || cleaned.match?(/ – | –|– /)
        errors << "double_hyphen" if cleaned.include?("--")
        errors << "url" if cleaned.match?(%r{https?://})
        errors << "markdown_link" if cleaned.include?("](")
        words = cleaned.split(/[[:space:]]+/).size
        errors << "too_short" if words < MIN_WORDS
        errors << "too_long" if words > MAX_WORDS

        Result.new(success?: errors.empty?, data: {text: cleaned}, errors: errors)
      end
    end
  end
end
