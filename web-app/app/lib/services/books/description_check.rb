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
    #
    # With source_text (an author's Wikipedia lead), a draft that repeats
    # COPY_RUN consecutive words of it fails as "copied".
    class DescriptionCheck
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # "([label](https://url))", the shape the model pastes in despite the
      # rules. The URLs are already in the run's citations. The URL segment
      # allows one level of balanced parens, since a Wikipedia disambiguation
      # URL such as .../Foo_(novel) is a likely citation target.
      MARKDOWN_CITATION = /\s*\(\[[^\]]*\]\((?:[^()\s]|\([^()\s]*\))*\)\)/
      MIN_WORDS = 40
      MAX_WORDS = 140
      # A draft that shares this many consecutive words with the text it was
      # written from is a close paraphrase of CC BY-SA text (spec §9), not a
      # description in our own words.
      COPY_RUN = 8

      def self.call(text, source_text: nil)
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
        errors << "copied" if copied?(cleaned, source_text)

        Result.new(success?: errors.empty?, data: {text: cleaned}, errors: errors)
      end

      def self.copied?(text, source_text)
        return false if source_text.blank?

        word_runs(text).intersect?(word_runs(source_text))
      end

      # Every run of COPY_RUN consecutive words, compared on letters and
      # digits only, so case, punctuation and quote styles cannot hide a copy.
      def self.word_runs(text)
        text.to_s.unicode_normalize(:nfkc).downcase.scan(/[\p{L}\p{N}]+/)
          .each_cons(COPY_RUN).map { |run| run.join(" ") }.to_set
      end
      private_class_method :copied?, :word_runs
    end
  end
end
