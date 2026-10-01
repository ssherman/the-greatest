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
    # COPY_RUN consecutive words of it fails as "copied". Work titles passed
    # as exempt_phrases may appear in both: naming a book is not copying.
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
      # A title shorter than this can only reach COPY_RUN shared words by
      # picking up five more identical words around it, and that is real
      # copying, not a shared title.
      MIN_EXEMPT_WORDS = 4

      # min_words lowers the floor for a caller whose descriptions may be
      # short by design: an author little is known about gets a few
      # sentences rather than padding.
      def self.call(text, source_text: nil, exempt_phrases: [], min_words: MIN_WORDS)
        cleaned = text.to_s.gsub(MARKDOWN_CITATION, "").strip
        errors = []
        # An em dash is always flagged. An en dash only counts as the same
        # violation when it is being used as a dash (spaced on at least one
        # side) rather than as a hyphen in a year range like "1939-1945".
        errors << "em_dash" if cleaned.include?("—") || cleaned.match?(/ – | –|– /)
        errors << "double_hyphen" if cleaned.include?("--")
        errors << "url" if cleaned.match?(%r{https?://})
        errors << "markdown_link" if cleaned.include?("](")
        word_count = cleaned.split(/[[:space:]]+/).size
        errors << "too_short" if word_count < min_words
        errors << "too_long" if word_count > MAX_WORDS
        errors << "copied" if copied?(cleaned, source_text, exempt_phrases)

        Result.new(success?: errors.empty?, data: {text: cleaned}, errors: errors)
      end

      def self.copied?(text, source_text, exempt_phrases)
        return false if source_text.blank?

        exempt = Array(exempt_phrases).map { |phrase| words(phrase) }
          .select { |tokens| tokens.size >= MIN_EXEMPT_WORDS }
          .map { |tokens| tokens.join(" ") }
          .uniq.sort_by { |phrase| -phrase.length }
        word_runs(text, exempt).intersect?(word_runs(source_text, exempt))
      end

      def self.words(text) = text.to_s.unicode_normalize(:nfkc).downcase.scan(/[\p{L}\p{M}\p{N}]+/)

      # Every run of COPY_RUN consecutive words, compared on letters, marks
      # and digits only, so case, punctuation and quote styles cannot hide a
      # copy. An exempt phrase (a work title both texts may name) breaks the
      # text where it stands, so no run spans it.
      def self.word_runs(text, exempt)
        joined = words(text).join(" ")
        exempt.each { |phrase| joined = joined.gsub(/(?<!\S)#{Regexp.escape(phrase)}(?!\S)/, "|") }
        joined.split("|").flat_map { |segment| segment.split.each_cons(COPY_RUN).map { |run| run.join(" ") } }.to_set
      end
      private_class_method :copied?, :words, :word_runs
    end
  end
end
