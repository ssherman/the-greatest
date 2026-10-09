# frozen_string_literal: true

module Recommendations
  # The taste profile (spec §6): per category, how much the user's positively
  # weighted books over-index on it versus the catalog, minus a share of how much
  # the negatively weighted ones do. Pure Ruby -- no database, no OpenSearch --
  # so every number here is unit-testable.
  class ProfileBuilder
    TYPE_LIMITS = {"genre" => :max_genres, "subject" => :max_subjects, "location" => :max_locations}.freeze

    def self.call(**args)
      new(**args).call
    end

    def initialize(interactions:, categories:, catalog_size:, type_category_ids:, config:)
      @interactions = interactions
      @categories = categories
      @catalog_size = [catalog_size.to_i, 1].max
      @type_ids = type_category_ids.values.to_set
      @fiction_id = type_category_ids["Fiction"]
      @nonfiction_id = type_category_ids["Nonfiction"]
      @config = config
    end

    def call
      positives = @interactions.select(&:positive?)
      negatives = @interactions.select(&:negative?)

      pos = lift_weights(positives, cap: @config[:lift_cap].to_f)
      neg = lift_weights(negatives, cap: 0.0)
      net = pos.to_h { |id, w| [id, w - @config[:negative_gamma] * neg.fetch(id, 0.0)] }
        .select { |_, w| w.positive? }
      demoted = neg.select { |id, w| !pos.key?(id) && w >= @config[:demote_threshold] }.keys

      Profile.new(
        genres: select_type(net, "genre"),
        subjects: select_type(net, "subject"),
        locations: select_type(net, "location"),
        demoted: demoted,
        fiction_share: fiction_share(positives),
        genre_distribution: genre_distribution(positives),
        counts: counts(positives, negatives)
      )
    end

    private

    # {category_id => weight}. With lift on: max(0, ln(s_c / p_c)), clipped to
    # `cap` when that is positive so a few rare categories cannot outvote the
    # genres (the positive profile only: a capped negative profile could never
    # reach demote_threshold); off: the raw share n_c / W, which reproduces the
    # legacy frequency behaviour for the harness baseline.
    def lift_weights(interactions, cap:)
      total = interactions.sum { |i| i.weight.abs }
      return {} if total <= 0

      mass = Hash.new(0.0)
      support = Hash.new(0)
      interactions.each do |interaction|
        facts_for(interaction.item_id).each do |fact|
          mass[fact.id] += interaction.weight.abs
          support[fact.id] += 1
        end
      end

      min_support = (interactions.size >= @config[:min_support_history]) ? @config[:min_support] : 1
      m = @config[:pseudo_books].to_f

      mass.each_with_object({}) do |(id, n), out|
        next if support[id] < min_support

        p = [fact_by_id[id].item_count.to_f / @catalog_size, 1.0 / @catalog_size].max
        weight = if @config[:lift]
          s = (n + m * p) / (total + m)
          lifted = [0.0, Math.log(s / p)].max
          cap.positive? ? [lifted, cap].min : lifted
        else
          n / total
        end
        out[id] = weight if weight.positive?
      end
    end

    def select_type(net, type)
      limit = @config[TYPE_LIMITS.fetch(type)]
      net.select { |id, _| fact_by_id[id].category_type == type }
        .sort_by { |id, w| [-w, id] }
        .first(limit)
    end

    # Type categories are excluded from scoring here, once, so no caller can
    # readmit them by raising a ceiling.
    def facts_for(item_id)
      @categories.fetch(item_id, []).reject { |f| @type_ids.include?(f.id) }
    end

    def fact_by_id
      @fact_by_id ||= @categories.values.flatten.index_by(&:id)
    end

    def fiction_share(positives)
      fiction = 0.0
      typed = 0.0
      positives.each do |interaction|
        ids = @categories.fetch(interaction.item_id, []).map(&:id)
        is_fiction = ids.include?(@fiction_id)
        is_nonfiction = ids.include?(@nonfiction_id)
        next unless is_fiction || is_nonfiction

        typed += interaction.weight
        fiction += interaction.weight if is_fiction
      end
      typed.positive? ? fiction / typed : nil
    end

    # Each positive book spreads its weight evenly over its genres, type genres
    # included: this is the distribution calibration (spec §8.1) matches.
    def genre_distribution(positives)
      dist = Hash.new(0.0)
      positives.each do |interaction|
        genres = @categories.fetch(interaction.item_id, []).select { |f| f.category_type == "genre" }
        next if genres.empty?

        genres.each { |g| dist[g.id] += interaction.weight / genres.size }
      end
      total = dist.values.sum
      return {} if total <= 0

      dist.transform_values { |v| v / total }
    end

    def counts(positives, negatives)
      {
        favorites: @interactions.count { |i| i.kind == :favorite },
        read: @interactions.count { |i| %i[read reading].include?(i.kind) },
        rated: @interactions.count { |i| !i.rating.nil? },
        positive: positives.size,
        negative: negatives.size
      }
    end
  end
end
