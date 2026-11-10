# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Trigram similarity mirroring pg_trgm, in Ruby so no database extension or
      # migration is needed: lowercase, split into words on non-alphanumerics, pad
      # each word as "  word ", take 3-character windows as a set.
      module Trigram
        module_function

        def words(text)
          text.to_s.downcase.split(/[^[:alnum:]]+/).reject(&:empty?)
        end

        def trigrams(text)
          trigrams_of_words(words(text))
        end

        def trigrams_of_words(word_list)
          word_list.each_with_object(Set.new) do |word, set|
            padded = "  #{word} "
            (0..padded.length - 3).each { |i| set << padded[i, 3] }
          end
        end

        # |A ∩ B| / |A ∪ B| of the two trigram sets.
        def similarity(a, b)
          jaccard(trigrams(a), trigrams(b))
        end

        # Best share of the query's trigrams found in any contiguous run of the
        # text's words that is as long as the query. A whole word inside a longer
        # name ("Paris" in "Parisian Suburbs") scores high though the names differ.
        # Containment, not Jaccard: pg_trgm trims the run to the matching extent,
        # which Jaccard over the whole run would not (Paris/Parisian is exactly 0.5).
        def word_similarity(query, text)
          query_words = words(query)
          text_words = words(text)
          return 0.0 if query_words.empty? || text_words.empty?

          query_set = trigrams_of_words(query_words)
          size = [query_words.size, text_words.size].min
          text_words.each_cons(size).map { |run| containment(query_set, trigrams_of_words(run)) }.max
        end

        def containment(query_set, run_set)
          return 0.0 if query_set.empty?

          (query_set & run_set).size.to_f / query_set.size
        end

        def jaccard(a, b)
          union = (a | b).size
          return 0.0 if union.zero?

          (a & b).size.to_f / union
        end
      end
    end
  end
end
