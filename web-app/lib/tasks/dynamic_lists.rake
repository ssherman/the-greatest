# frozen_string_literal: true

namespace :dynamic_lists do
  # Brings hand-created year rollup lists under the generator's ownership.
  #
  # MUST run before the first generate. Without it the generator finds no list at
  # (type, kind, year), creates a new pair, and the originals keep their items
  # attached to the primary configuration -- double-counting every item in them.
  #
  # Bridges via primary_mapped_list_id rather than by name: the pointers already
  # identify the right lists, and the year comes from the primary list's
  # year_published, which is data rather than a string parsed out of a title.
  desc "Adopt existing mapped lists as generator-owned year rollups (idempotent)"
  task adopt: :environment do
    adopted = 0

    RankingConfiguration.where.not(primary_mapped_list_id: nil).find_each do |config|
      top = config.primary_mapped_list
      overflow = config.secondary_mapped_list
      year = top&.year_published

      if year.blank?
        puts "SKIP #{config.id} #{config.name.inspect}: primary mapped list has no year_published."
        next
      end

      # assign_attributes + save!(validate: false), not update!: this task only
      # ever writes booleans, integers and the primary list's year onto fields
      # it owns (a RankingConfiguration's year/cutoff, a List's
      # auto_generated_kind/auto_generated_year). `update!` validates the
      # ENTIRE record, so a pre-existing invalid value on a column this task
      # never touches would still abort adoption. It does on real data: 50
      # books lists carry a `url` with a leading space (" https://...") that
      # fails List's format validation -- running this task against
      # development aborted after adopting 2024 and 2023, leaving 2025
      # unstamped. Not update_columns: that skips callbacks too and leaves
      # updated_at unchanged, and the admin show page renders
      # `time_ago_in_words(list.updated_at)` as the "generated N ago"
      # indicator.
      config.year = year if config.year.blank?
      config.secondary_mapped_list_cutoff_limit = 400 if config.secondary_mapped_list_cutoff_limit.blank?
      config.save!(validate: false) if config.changed?

      top.assign_attributes(auto_generated_kind: :year_top, auto_generated_year: year)
      top.save!(validate: false)
      puts "ADOPT list #{top.id} #{top.name.inspect} as year_top #{year} (#{top.list_items.count} items)."

      if overflow
        overflow.assign_attributes(auto_generated_kind: :year_honorable_mention, auto_generated_year: year)
        overflow.save!(validate: false)
        puts "ADOPT list #{overflow.id} #{overflow.name.inspect} as year_honorable_mention #{year} " \
          "(#{overflow.list_items.count} items)."
      else
        puts "NOTE  #{config.name.inspect} has no secondary mapped list; only the top list was adopted."
      end

      adopted += 1
    end

    puts "Done. Adopted #{adopted} configuration(s)."
  end

  # Rebuilds every year configuration of a type, one at a time, then refreshes
  # the primary configuration ONCE rather than once per year -- for books that
  # is the difference between one pass over 623 lists and three.
  #
  # Each generator runs INLINE (`.new.perform`, not `perform_async`) so this
  # process blocks until it finishes before starting the next. That is not
  # optional: `config/sidekiq.yml` runs 5 concurrent threads against the
  # `default` queue (the single-threaded `serial` capsule in
  # config/initializers/sidekiq.rb does not cover it), so enqueuing one job per
  # year plus a trailing CalculateRankingsJob would let that refresh start
  # ALONGSIDE the generators and read each mapped list's pre-regeneration
  # list_items and stale ranked_lists.weight -- the exact stale-ordering bug
  # this feature exists to eliminate. Running inline here costs well under a
  # second per year configuration (weights + rankings) and guarantees every
  # generator has completed, and the primary's weights for those lists are
  # current, before the single CalculateRankingsJob is enqueued.
  desc "Regenerate every year configuration of a type in order, then queue one primary refresh"
  task :regenerate, [:type] => :environment do |_task, args|
    type = args[:type]
    raise ArgumentError, "Pass a ranking configuration type, e.g. Books::RankingConfiguration" if type.blank?

    config_class = type.constantize
    # `where(primary: false)` on top of `where.not(year: nil)`: the admin form
    # exposes `year` on every configuration type, so nothing stops an operator
    # setting it on the domain's primary configuration too. Regenerating that
    # row would overwrite it with a year-scoped top list that then feeds back
    # into itself -- see the guard in Services::Lists::GenerateDynamicLists,
    # which is the same reason this scope excludes it here.
    configs = config_class.where.not(year: nil).where(primary: false).order(:year)

    if configs.empty?
      puts "No year configurations found for #{type}."
      next
    end

    configs.each do |config|
      puts "Regenerating #{config.name.inspect} (#{config.year})."
      GenerateDynamicListsJob.new.perform(config.id, false)
    end

    main = config_class.default_primary
    if main
      puts "Queueing one ranking refresh for #{main.name.inspect}."
      CalculateRankingsJob.perform_async(main.id)
    end

    puts "Done. Regenerated #{configs.count} configuration(s)."
  end
end
