# frozen_string_literal: true

module Actions
  module Admin
    # Builds the next year's ranking configuration for a domain, fully set up.
    #
    # Replaces hand-assembly that had already drifted three years running: 2023
    # and 2024 use exponent 1.5 while 2025 uses 3.0, and their penalty sets differ
    # by more than the tuning justifies.
    class CreateNextYearConfiguration < Actions::Admin::BaseAction
      # Inside a single-year configuration every list covers the same one year, so
      # a time-scope penalty fires on everything or nothing and carries no signal
      # either way. All 7 of these were already absent from all three existing year
      # configurations -- the rule was being applied by hand, just never written down.
      EXCLUDED_CATEGORY = "list_time_scope"
      EXCLUDED_DYNAMIC_TYPE = "num_years_covered"

      DEFAULT_PRIMARY_CUTOFF = 100
      # Ranks 101-500. Under the primary configuration's "contains over 500 items"
      # threshold, so a generated overflow list never trips it.
      DEFAULT_SECONDARY_CUTOFF = 400

      def self.name
        "Create Next Year's Configuration"
      end

      def self.message
        "Create the next year's configuration, copying settings and penalties forward."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        return error("#{config.class.name} does not support year rollups.") unless config.supports_year_rollups?

        config_class = config.class
        previous = config_class.where.not(year: nil).order(year: :desc).first
        main = config_class.default_primary
        source = previous || main

        return error("#{config_class.name} has no configuration to copy from.") if source.nil?

        target_year = previous ? previous.year + 1 : Date.current.year

        from_previous = previous ? applicable_values(previous) : {}
        from_main = main ? applicable_values(main) : {}
        merged = from_main.merge(from_previous)
        added = (from_main.keys - from_previous.keys).size
        skipped = skipped_count(previous, main)

        new_config = build_configuration(config_class, source, target_year)

        # PenaltyApplication validates presence of ranking_configuration_id
        # directly (not just the association), and that column is only
        # backfilled on the built children once the parent is actually
        # persisted -- so the parent must be saved first, and the penalty
        # applications attached in a second step, both inside one transaction
        # so a failure on either side leaves nothing behind.
        ActiveRecord::Base.transaction do
          raise ActiveRecord::Rollback unless new_config.save

          merged.each do |penalty_id, value|
            penalty_application = new_config.penalty_applications.build(penalty_id: penalty_id, value: value)
            unless penalty_application.save
              new_config.errors.merge!(penalty_application.errors)
              raise ActiveRecord::Rollback
            end
          end
        end

        unless new_config.persisted?
          return error("Could not create the #{target_year} configuration: #{new_config.errors.full_messages.join(", ")}")
        end

        succeed(
          "Created #{new_config.name}: #{from_previous.size} penalties copied forward, " \
            "#{added} added from #{main&.name || "the primary configuration"}, " \
            "#{skipped} time-scope penalties skipped. " \
            "Attach this year's lists to it, then generate.",
          data: {
            ranking_configuration: new_config,
            copied: from_previous.size,
            added: added,
            skipped: skipped
          }
        )
      end

      private

      def build_configuration(config_class, source, target_year)
        config_class.new(
          name: "The Best #{source.generated_list_noun} of #{target_year}",
          description: "Year-scoped ranking configuration for #{target_year} " \
            "#{source.generated_list_noun.downcase}.",
          year: target_year,
          global: true,
          primary: false,
          archived: false,
          published_at: nil,
          algorithm_version: source.algorithm_version,
          exponent: source.exponent,
          bonus_pool_percentage: source.bonus_pool_percentage,
          min_list_weight: source.min_list_weight,
          inherit_penalties: source.inherit_penalties,
          # Forced, not copied. Every list in a year configuration is from that
          # year, so the date penalty has nothing to discriminate -- and cloning
          # from the primary configuration would inherit `true` and penalise a
          # 2026 book for appearing on a 2026 list.
          apply_list_dates_penalty: false,
          max_list_dates_penalty_age: nil,
          max_list_dates_penalty_percentage: nil,
          primary_mapped_list_cutoff_limit:
            source.primary_mapped_list_cutoff_limit || DEFAULT_PRIMARY_CUTOFF,
          secondary_mapped_list_cutoff_limit:
            source.secondary_mapped_list_cutoff_limit || DEFAULT_SECONDARY_CUTOFF
        )
      end

      def applicable_values(config)
        config.penalty_applications.includes(:penalty)
          .reject { |application| excluded?(application.penalty) }
          .to_h { |application| [application.penalty_id, application.value] }
      end

      # The dynamic_type clause is belt-and-braces. Today every penalty carries a
      # category and the one dynamic time penalty is categorised correctly, but
      # `category` is nullable and a penalty created in admin can arrive without one.
      def excluded?(penalty)
        penalty.category == EXCLUDED_CATEGORY || penalty.dynamic_type == EXCLUDED_DYNAMIC_TYPE
      end

      def skipped_count(previous, main)
        [previous, main].compact.flat_map { |config|
          config.penalty_applications.includes(:penalty)
            .select { |application| excluded?(application.penalty) }
            .map(&:penalty_id)
        }.uniq.size
      end
    end
  end
end
