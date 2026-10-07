# frozen_string_literal: true

# Read-only development harness for the recommendation engine (spec §9). Never
# writes to the database or the index. Every knob is a per-call override, so one
# process sweeps a range:
#
#   bin/rails recommendations:show USER=123 [LIMIT=50] [VARIANTS="lift=false; calibrate_genres=false"]
#   bin/rails recommendations:eval [USERS=500] [SEED=42] [LIMIT=50] [FRACTION=0.2] [VARIANTS="lift=false"]
#
# eval always reports two baselines beside the variants: `rank` (the filtered
# pool in global-rank order) and `lift=false` (raw frequency share, which is
# the legacy engine's behaviour).
module RecommendationsHarness
  module_function

  def parse_variants(raw)
    specs = [{}]
    return specs if raw.blank?

    raw.split(";").each do |chunk|
      overrides = chunk.split(",").each_with_object({}) do |pair, acc|
        key, value = pair.split("=", 2).map(&:strip)
        acc[key.to_sym] = cast(value) if key.present? && !value.nil?
      end
      specs << overrides if overrides.any?
    end
    specs
  end

  def cast(value)
    case value
    when /\A-?\d+\z/ then value.to_i
    when /\A-?\d*\.\d+\z/ then value.to_f
    when "true" then true
    when "false" then false
    else value
    end
  end

  def label(overrides)
    overrides.empty? ? "shipped defaults" : overrides.map { |k, v| "#{k}=#{v}" }.join("  ")
  end

  def reason_text(reason, names)
    case reason.type
    when :because_of then "because you loved #{names[reason.ids.first] || reason.ids.first}"
    when :interests then "matches #{reason.ids.map { |id| names[id] || id }.join(" + ")}"
    else "ranked ##{reason.ids.first || "?"}"
    end
  end

  def category_names(ids)
    ::Category.where(id: ids).pluck(:id, :name).to_h
  end

  def mean(values)
    values.empty? ? 0.0 : values.sum.to_f / values.size
  end

  def fmt(value)
    format("%.3f", value)
  end
end

namespace :recommendations do
  desc "Print one user's profile and recommendations with reasons (USER=id, LIMIT, VARIANTS)"
  task show: :environment do
    user = User.find(ENV.fetch("USER"))
    limit = ENV.fetch("LIMIT", "50").to_i
    variants = RecommendationsHarness.parse_variants(ENV["VARIANTS"])

    variants.each do |overrides|
      puts "=" * 100
      puts "#{user.display_name.presence || user.email} (#{user.id}) -- #{RecommendationsHarness.label(overrides)}"
      result = Recommendations::Engine.call(user: user, domain: :books, limit: limit, overrides: overrides)
      abort result.errors.join(", ") unless result.success?

      profile = result.data[:profile]
      names = RecommendationsHarness.category_names(profile.scored_ids + profile.demoted)
      puts "  counts: #{profile.counts}  fiction_share: #{profile.fiction_share&.round(2).inspect}  signals: #{result.data[:signals_used]}#{" FALLBACK" if result.data[:fallback]}"
      {genres: profile.genres, subjects: profile.subjects, locations: profile.locations}.each do |type, pairs|
        puts "  #{type}: " + pairs.map { |id, w| "#{names[id]}(#{w.round(2)})" }.join(", ")
      end
      puts "  demoted: " + profile.demoted.map { |id| names[id] }.join(", ") if profile.demoted.any?
      puts

      page_names = RecommendationsHarness.category_names(result.data[:items].flat_map { |i| i[:reason].ids if i[:reason].type == :interests }.compact)
      result.data[:items].each do |entry|
        book = entry[:item]
        authors = book.book_authors.filter_map { |ba| ba.author&.name }.join(", ")
        puts format("  %3d. %-55s %-25s rank %-6s %s", entry[:rank], book.title[0, 55], authors[0, 25],
          book.primary_ranked_item&.rank || "-", RecommendationsHarness.reason_text(entry[:reason], page_names))
      end
      puts
    end
  end

  desc "Offline hold-out evaluation across user segments (USERS, SEED, LIMIT, FRACTION, VARIANTS)"
  task eval: :environment do
    users_total = ENV.fetch("USERS", "500").to_i
    seed = ENV.fetch("SEED", "42").to_i
    limit = ENV.fetch("LIMIT", "50").to_i
    fraction = ENV.fetch("FRACTION", "0.2").to_f
    variants = RecommendationsHarness.parse_variants(ENV["VARIANTS"])
    variants << {lift: false} unless variants.any? { |v| v[:lift] == false }

    random = Random.new(seed)
    segments = Recommendations::Evaluation.sample_user_ids(domain: :books, per_segment: users_total / 3, random: random)
    config = Recommendations::Config.resolve
    adapter = Recommendations::Books::Adapter.new(config: config)
    pool_size = ::RankedItem.where(item_type: "Books::Book", ranking_configuration_id: ::Books::RankingConfiguration.default_primary&.id).count

    puts "Recommendations evaluation  users=#{segments.values.sum(&:size)}  seed=#{seed}  hold-out=#{fraction}  limit=#{limit}"
    puts "variants: rank baseline | " + variants.map { |v| RecommendationsHarness.label(v) }.join(" | ")
    puts

    segments.each do |segment, user_ids|
      rows = Hash.new { |h, k| h[k] = {hit: [], recall: [], ndcg: [], mean_rank: [], author_repeats: [], kl: [], ms: [], ids: Set.new} }
      evaluated = 0

      user_ids.each do |user_id|
        user = User.find(user_id)
        interactions = adapter.interactions(user)
        train, held = Recommendations::Evaluation.split(interactions, fraction: fraction, random: Random.new(seed + user_id))
        next if held.size < 1 || interactions.count { |i| Recommendations::Evaluation.eligible?(i) } < 5

        evaluated += 1
        held_ids = held.map(&:item_id)
        excluded = adapter.shelved_item_ids(user) - held_ids
        criteria = adapter.criteria_for(user)

        # Baseline: the filtered pool in global rank order.
        rank_ids = adapter.rank_ordered_candidates(criteria: criteria, excluded_ids: excluded, size: limit).map(&:item_id)
        m = Recommendations::Evaluation.metrics(page_ids: rank_ids, held_out_ids: held_ids)
        rows["rank"][:hit] << m[:hit]
        rows["rank"][:recall] << m[:recall]
        rows["rank"][:ndcg] << m[:ndcg]

        variants.each do |overrides|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = Recommendations::Engine.call(user: user, domain: :books, limit: limit, overrides: overrides,
            interactions: train, excluded_ids: excluded)
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          next unless result.success?

          items = result.data[:items]
          page_ids = items.map { |i| i[:item_id] }
          facts = adapter.item_facts(page_ids)
          m = Recommendations::Evaluation.metrics(page_ids: page_ids, held_out_ids: held_ids)
          row = rows[RecommendationsHarness.label(overrides)]
          row[:hit] << m[:hit]
          row[:recall] << m[:recall]
          row[:ndcg] << m[:ndcg]
          row[:ms] << ms
          row[:ids].merge(page_ids)
          ranks = page_ids.filter_map { |id| facts[id]&.rank_position }
          row[:mean_rank] << RecommendationsHarness.mean(ranks) if ranks.any?
          author_counts = page_ids.flat_map { |id| facts[id]&.author_ids || [] }.tally.values
          row[:author_repeats] << author_counts.sum { |c| c - 1 }
          row[:kl] << Recommendations::Evaluation.genre_kl(history: result.data[:profile].genre_distribution,
            page_genres: page_ids.map { |id| facts[id]&.genre_ids || [] }, alpha: config[:calibration_alpha])
        end
      end

      puts "-- segment #{segment}: #{evaluated} of #{user_ids.size} sampled users evaluated"
      puts "   #{"variant".ljust(36)}  hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms"
      rows.each do |name, r|
        puts format("   %-36s %7s %9s %8s %9s %8s %7s %9s %6s", name[0, 36],
          RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:hit])),
          RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:recall])),
          RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:ndcg])),
          r[:mean_rank].empty? ? "-" : RecommendationsHarness.mean(r[:mean_rank]).round,
          r[:author_repeats].empty? ? "-" : RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:author_repeats])),
          r[:kl].empty? ? "-" : RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:kl])),
          pool_size.zero? ? "-" : RecommendationsHarness.fmt(r[:ids].size.to_f / pool_size),
          r[:ms].empty? ? "-" : RecommendationsHarness.mean(r[:ms]).round)
      end
      puts
    end
  end
end
