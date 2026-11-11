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

        # A text's trigram set and per-word sets, computed once so a caller scoring
        # many rows against one query does not rebuild them on every comparison.
        Profile = Struct.new(:trigrams, :word_sets)

        def profile(text)
          word_sets = words(text).map { |word| trigrams_of_words([word]) }
          Profile.new(word_sets.reduce(Set.new, :|), word_sets)
        end

        # |A ∩ B| / |A ∪ B| of the two trigram sets.
        def similarity(a, b)
          similarity_of(profile(a), profile(b))
        end

        def similarity_of(a, b)
          jaccard(a.trigrams, b.trigrams)
        end

        def word_similarity(query, text)
          word_similarity_of(profile(query), profile(text))
        end

        # Containment: the best share of the query's trigrams found in any
        # contiguous run of the text's words that is as many words as the query.
        # A whole word inside a longer name ("Paris" in "Parisian Suburbs") scores
        # high. This is NOT pg_trgm's word_similarity, which scores the best
        # contiguous trigram extent; containment is more generous (Jaccard over a
        # whole word would put Paris/Parisian at exactly 0.5).
        def word_similarity_of(query, text)
          return 0.0 if query.word_sets.empty? || text.word_sets.empty?

          size = [query.word_sets.size, text.word_sets.size].min
          text.word_sets.each_cons(size).map { |run| containment(query.trigrams, run.reduce(Set.new, :|)) }.max
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
