# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Deterministic name repair for the rules pass (spec §4.2 step 1) and the
    # comparison key every stage uses to tell whether two names are the same.
    module NameNormalizer
      DASHES = /[‐-―−]/
      SINGLE_QUOTES = /[‘’‚‛′]/
      DOUBLE_QUOTES = /[“”„‟″]/
      MINOR_WORDS = %w[a an and as at but by for in nor of on or the to with].freeze

      module_function

      def clean(name)
        name.to_s.unicode_normalize(:nfkc)
          .gsub(DASHES, "-").gsub(SINGLE_QUOTES, "'").gsub(DOUBLE_QUOTES, '"')
          .gsub(/\s+/, " ").strip
      end

      # Case, spacing and punctuation-insensitive. "&" is NOT folded into "and"
      # here; target_name rewrites "&" first so those twins meet.
      # Returns nil when nothing alphanumeric is left, so callers can skip it.
      # "C++" and "C#" are encoded first so C, C++ and C# are never twins, while
      # "LGBTQ+" and "LGBTQ" still are.
      def twin_key(name)
        encoded = clean(name).gsub(/(?<![[:alnum:]])([[:alpha:]])(\+\+|#)/) { "#{$1}#{($2 == "#") ? "sharp" : "plusplus"}" }
        key = encoded.downcase.gsub(/[^[:alnum:]]/, "")
        key.presence
      end

      # The name a category should have, or :delete for a bracket fragment with
      # no letters ("61)", "2014)"). Names with balanced brackets and no letters
      # ("9/11") are left for the AI.
      def target_name(name)
        cleaned = clean(name).sub(/[\s,;:]+\z/, "")
        repaired = repair_brackets(cleaned)
        return :delete if repaired == :delete

        repaired = repaired.sub(/[\s,;:]+\z/, "")
        return :delete if repaired.blank?

        repaired = repaired.gsub(/\s*&\s*/, " and ")
        repaired = title_case(repaired) if repaired.match?(/\A[[:lower:]]/)
        repaired
      end

      # Cuts at the first unmatched "(" (or drops a trailing unmatched ")").
      # A leading unmatched "(" is just dropped: "(Japan" is "Japan".
      def repair_brackets(name)
        depth_stack = []
        name.each_char.with_index do |char, index|
          if char == "("
            depth_stack << index
          elsif char == ")" && depth_stack.any?
            depth_stack.pop
          end
        end
        extra_closes = name.count(")") - (name.count("(") - depth_stack.size)
        return name if depth_stack.empty? && extra_closes.zero?

        remainder = if depth_stack.any?
          cut = depth_stack.first
          cut.zero? ? name[1..] : name[0...cut]
        else
          name.sub(/\)\s*\z/, "")
        end
        remainder = remainder.strip
        remainder.match?(/[[:alpha:]]/) ? remainder : :delete
      end

      # Capitalises the first letter of words with no capitals, keeps minor words lowercase after the
      # first, and leaves mixed-case words ("iPhone") alone.
      def title_case(name)
        name.split(" ").each_with_index.map do |word, index|
          if index.positive? && MINOR_WORDS.include?(word)
            word
          elsif word.match?(/\A[^[:upper:]]*\z/)
            word.sub(/\A[[:lower:]]/, &:upcase)
          else
            word
          end
        end.join(" ")
      end
    end
  end
end
