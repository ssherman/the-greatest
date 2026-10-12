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
      def twin_key(name)
        clean(name).downcase.gsub(/[^[:alnum:]]/, "")
      end

      # The name a category should have, or :delete for a bracket fragment with
      # no letters ("61)", "2014)"). Names with balanced brackets and no letters
      # ("9/11") are left for the AI.
      def target_name(name)
        cleaned = clean(name).sub(/[\s,;:]+\z/, "")
        repaired = repair_brackets(cleaned)
        return :delete if repaired == :delete || repaired.blank?

        repaired = repaired.gsub(/\s*&\s*/, " and ")
        repaired = title_case(repaired) if repaired.match?(/\A[[:lower:]]/)
        repaired
      end

      def repair_brackets(name)
        opens = name.count("(")
        closes = name.count(")")
        return name if opens == closes

        remainder = (opens > closes) ? name[0...name.rindex("(")] : name.sub(/\)\s*\z/, "")
        remainder = remainder.strip
        remainder.match?(/[[:alpha:]]/) ? remainder : :delete
      end

      # Capitalises all-lowercase words, keeps minor words lowercase after the
      # first, and leaves mixed-case words ("iPhone") alone.
      def title_case(name)
        name.split(" ").each_with_index.map do |word, index|
          if index.positive? && MINOR_WORDS.include?(word)
            word
          elsif word.match?(/\A[[:lower:]]+\z/)
            word.capitalize
          else
            word
          end
        end.join(" ")
      end
    end
  end
end
