# frozen_string_literal: true

module Recommendations
  # The offline evaluation's arithmetic (spec §9.1), kept out of the rake task
  # so it is unit-tested. Hold-out: hide a fraction of the user's favorites and
  # 4-plus ratings, recommend from the rest, and see whether the hidden books
  # come back. The rake task owns sampling at scale, timing, and printing.
  module Evaluation
    SEGMENTS = {"5-19" => (5..19), "20-99" => (20..99), "100+" => (100..)}.freeze
    HOLD_OUT_RATING = 4
    MIN_ELIGIBLE = 5

    module_function

    def eligible?(interaction)
      interaction.kind == :favorite || (interaction.rating && interaction.rating >= HOLD_OUT_RATING)
    end

    def split(interactions, fraction:, random:)
      eligible = interactions.select { |i| eligible?(i) }
      count = (eligible.size * fraction).ceil
      held = eligible.sort_by(&:item_id).sample(count, random: random)
      held_ids = held.map(&:item_id).to_set
      [interactions.reject { |i| held_ids.include?(i.item_id) }, held]
    end

    def metrics(page_ids:, held_out_ids:, k_hit: 10, k_recall: 50)
      held = held_out_ids.to_set
      top = page_ids.first(k_recall)
      hits = top.each_index.select { |i| held.include?(top[i]) }
      dcg = hits.sum { |i| 1.0 / Math.log2(i + 2) }
      ideal = [held.size, k_recall].min
      idcg = (0...ideal).sum { |i| 1.0 / Math.log2(i + 2) }
      {
        hit: (page_ids.first(k_hit).any? { |id| held.include?(id) }) ? 1 : 0,
        recall: held.empty? ? 0.0 : hits.size.to_f / held.size,
        ndcg: idcg.zero? ? 0.0 : dcg / idcg
      }
    end

    # KL(history ‖ smoothed page) over genre ids; page_genres is one array of
    # genre ids per recommended item. Same smoothing as GenreCalibration.
    def genre_kl(history:, page_genres:, alpha:)
      mass = Hash.new(0.0)
      page_genres.each { |genres| genres.each { |g| mass[g] += 1.0 / genres.size } if genres.any? }
      total = mass.values.sum
      return 0.0 if total <= 0 || history.empty?

      history.sum do |genre, p|
        q = mass.fetch(genre, 0.0) / total
        p * Math.log(p / ((1 - alpha) * q + alpha * p))
      end
    end

    # Eligible users -- at least MIN_ELIGIBLE hold-out candidates (favorites plus
    # reviews rated HOLD_OUT_RATING or higher) -- mapped to their positive list-item
    # count (favorites + read + reading), the figure the segments bucket on. Two
    # GROUP BYs for eligibility and one for the count, instead of building every
    # user's interactions. A favorite that is also rated 4-plus counts twice toward
    # eligibility; the per-user check in the rake task is the exact one.
    def eligible_positive_counts(domain:)
      klass = ::UserList.subclasses_for(domain).first or raise ArgumentError, "no user lists for domain #{domain}"
      listable = klass.listable_class.name
      items = ::UserListItem.joins(:user_list)

      favorites = items.where(user_lists: {type: klass.name, list_type: klass.list_types["favorites"]}, listable_type: listable)
        .group("user_lists.user_id").count
      rated = ::Review.where(reviewable_type: listable).where("rating >= ?", HOLD_OUT_RATING).group(:user_id).count
      eligible = favorites.merge(rated) { |_, a, b| a + b }.select { |_, n| n >= MIN_ELIGIBLE }.keys

      positive_types = klass.list_types.slice("favorites", "read", "reading").values
      items.where(user_lists: {type: klass.name, list_type: positive_types, user_id: eligible})
        .group("user_lists.user_id").count
    end

    def sample_user_ids(domain:, per_segment:, random:)
      counts = eligible_positive_counts(domain: domain)

      SEGMENTS.to_h do |label, range|
        ids = counts.select { |_, n| range.cover?(n) }.keys.sort
        [label, ids.sample(per_segment, random: random)]
      end
    end
  end
end
