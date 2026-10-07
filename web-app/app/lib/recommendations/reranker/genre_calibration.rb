# frozen_string_literal: true

module Recommendations
  module Reranker
    # Greedy calibrated selection (Steck 2018; spec §8.1): pick the next book that
    # maximises (1 - λ) · relevance - λ · KL(history ‖ page), where both
    # distributions are over genre ids and each book spreads 1 evenly over its
    # genres. The page distribution is smoothed toward the history by α so KL is
    # finite for a genre the page does not yet carry. Relevance is the fused
    # score divided by the best fused score, so λ means the same thing whatever
    # scale fusion produced.
    module GenreCalibration
      def self.call(candidates, facts:, history:, limit:, config:)
        return candidates.first(limit) if !config[:calibrate_genres] || history.empty? || candidates.empty?

        lambda_ = config[:calibration_lambda].to_f
        alpha = config[:calibration_alpha].to_f
        best = candidates.map(&:score).max
        best = 1.0 unless best&.positive?

        remaining = candidates.dup
        selected = []
        page_mass = Hash.new(0.0)

        while selected.size < limit && remaining.any?
          pick = remaining.max_by.with_index do |candidate, index|
            relevance = candidate.score / best
            kl = kl_after_adding(page_mass, selected.size, genres_of(candidate, facts), history, alpha)
            [(1 - lambda_) * relevance - lambda_ * kl, -index]
          end
          selected << pick
          remaining.delete(pick)
          add_genres(page_mass, genres_of(pick, facts))
        end
        selected
      end

      def self.genres_of(candidate, facts)
        facts[candidate.item_id]&.genre_ids || []
      end

      def self.add_genres(page_mass, genres)
        return if genres.empty?

        genres.each { |g| page_mass[g] += 1.0 / genres.size }
      end

      # KL(history ‖ smoothed page) if `genres` were added to the page.
      def self.kl_after_adding(page_mass, selected_count, genres, history, alpha)
        trial = page_mass.dup
        genres.each { |g| trial[g] += 1.0 / genres.size } if genres.any?
        total = trial.values.sum
        return 0.0 if total <= 0

        history.sum do |genre, p|
          q = trial.fetch(genre, 0.0) / total
          q_smoothed = (1 - alpha) * q + alpha * p
          p * Math.log(p / q_smoothed)
        end
      end

      private_class_method :genres_of, :add_genres, :kl_after_adding
    end
  end
end
