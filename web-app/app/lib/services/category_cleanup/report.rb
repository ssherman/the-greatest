# frozen_string_literal: true

require "csv"

module Services
  module CategoryCleanup
    # What the owner reviews before apply (spec §4.3): counts, the largest
    # merges, the locations apply would create, proposed roots, ambiguous
    # names, failures, undecided head-tier categories, merges into categories
    # that are themselves going away, and seeded random samples per action.
    # The full list goes to a CSV.
    class Report
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      SAMPLE_SIZE = 25
      TOP_MERGES = 50
      TERMINAL_ACTIONS = %w[merge retype delete].freeze

      def self.call(run:, out_dir: Rails.root.join("tmp"))
        new(run: run, out_dir: out_dir).call
      end

      # Head-tier categories (own links >= head_min) with no decision in this
      # type's head/tail stages: failed head calls or count drift. Most-linked first.
      def self.undecided_head(run:, category_type:)
        head_min = Rails.configuration.x.categories_cleanup.head_min_links
        stages = %w[head tail].map { |tier| "#{category_type.to_s.pluralize}_#{tier}" }
        seen = ::CategoryCleanupDecision.for_run(run).where(stage: stages).distinct.pluck(:category_id).to_set
        NameIndex.new(run: run, category_type: category_type).entries
          .select { |entry| entry.own_links >= head_min && !seen.include?(entry.id) }
          .sort_by { |entry| [-entry.links, entry.id] }
      end

      def initialize(run:, out_dir:)
        @run = run
        @out_dir = Pathname(out_dir)
      end

      def call
        lines = ["Category cleanup run #{@run}: #{decisions.count} decisions"]
        section(lines, "By stage, action and status") do
          decisions.group(:stage, :action, :status).count.sort_by { |key, _| key.map(&:to_s) }
            .map { |(stage, action, status), count| "#{stage} #{action} #{status}: #{count}" }
        end
        section(lines, "Undecided head-tier categories") { undecided_head_rows }
        section(lines, "Largest merges (links moved)") { largest_merges }
        section(lines, "Merges into a category with its own pending terminal decision") { chained_merges }
        section(lines, "Locations apply would create") { would_create }
        section(lines, "Proposed roots") do
          decisions.proposed.action_keep.where.not(place_kind: nil).includes(:category).map { |d| "#{d.category.name} (#{d.place_kind})" }.sort
        end
        section(lines, "Ambiguous names") { decisions.where(ambiguous: true).map { |d| d.category_snapshot["name"] }.uniq.sort }
        section(lines, "Failed") { decisions.failed.map { |d| "#{d.category_snapshot["name"]} [#{d.action}]: #{d.error}" } }
        ::CategoryCleanupDecision.actions.each_key do |action|
          section(lines, "Sample: #{action}") do
            decisions.proposed.where(action: action).includes(:target_category)
              .order(Arel.sql("md5(category_cleanup_decisions.id::text)")).limit(SAMPLE_SIZE).map { |d| describe(d) }
          end
        end

        Result.new(success?: true, data: {lines: lines, csv_path: write_csv.to_s}, errors: [])
      end

      private

      def decisions = ::CategoryCleanupDecision.for_run(@run)

      def section(lines, title)
        rows = yield
        lines << "" << "#{title}:"
        lines.concat(rows.empty? ? ["  (none)"] : rows.map { |row| "  #{row}" })
      end

      def undecided_head_rows
        %w[location subject].filter_map do |type|
          entries = self.class.undecided_head(run: @run, category_type: type)
          next if entries.empty?

          names = entries.first(SAMPLE_SIZE).map(&:name).join(", ")
          "#{type}: #{entries.size} (#{names}#{", ..." if entries.size > SAMPLE_SIZE}) -- re-run the #{type} head stage"
        end
      end

      def largest_merges
        decisions.proposed.action_merge.includes(:target_category).to_a
          .sort_by { |d| -d.category_snapshot["item_count"].to_i }.first(TOP_MERGES)
          .map { |d| "#{d.category_snapshot["name"]} (#{d.category_snapshot["item_count"]}) -> #{d.target_category&.name}" }
      end

      # A merge whose target is itself being merged, retyped or deleted in this
      # run: the applier moves the links twice or supersedes one of them.
      def chained_merges
        terminal_ids = decisions.proposed.where(action: TERMINAL_ACTIONS).distinct.pluck(:category_id)
        decisions.proposed.action_merge.where(target_category_id: terminal_ids).includes(:target_category).order(:id)
          .map { |d| "#{d.category_snapshot["name"]} -> #{d.target_category.name}" }
      end

      def would_create
        lookup = LocationLookup.new
        names = decisions.proposed.action_set_parent.flat_map(&:parent_chain)
          .select { |name| NameNormalizer.twin_key(name) }
          .uniq { |name| NameNormalizer.twin_key(name) }
          .reject { |name| lookup.find(name) }
          .sort
        taken = taken_slugs(names.map(&:parameterize))
        names.map do |name|
          slug = name.parameterize
          "#{name} [#{slug}]#{" (slug taken → will get a UUID suffix)" if taken.include?(slug)}"
        end
      end

      # Slugs held by any books category (deleted ones too) or by friendly_id history.
      def taken_slugs(slugs)
        ::Books::Category.where(slug: slugs).pluck(:slug).to_set |
          ::FriendlyId::Slug.where(sluggable_type: "Category", slug: slugs).pluck(:slug).to_set
      end

      def describe(decision)
        detail = case decision.action
        when "rename" then decision.new_name
        when "merge" then decision.target_category&.name
        when "set_parent" then decision.parent_chain.join(" > ")
        when "retype" then ::Category.category_types.key(decision.new_category_type)
        end
        ["#{decision.category_snapshot["name"]} -> #{decision.action}", detail, ("(#{decision.reason})" if decision.reason.present?)].compact.join(" ")
      end

      def write_csv
        FileUtils.mkdir_p(@out_dir)
        path = @out_dir.join("category_cleanup_#{@run.parameterize}.csv")
        CSV.open(path, "w") do |csv|
          csv << %w[id stage status decided_by action category_id name category_type links new_name target parent_chain new_category_type place_kind ambiguous reason error]
          decisions.includes(:target_category).order(:id).find_each do |d|
            snapshot = d.category_snapshot
            csv << [d.id, d.stage, d.status, d.decided_by, d.action, d.category_id, snapshot["name"], snapshot["category_type"], snapshot["item_count"],
              d.new_name, d.target_category&.name, d.parent_chain.join(" > "), d.new_category_type && ::Category.category_types.key(d.new_category_type),
              d.place_kind, d.ambiguous, d.reason, d.error]
          end
        end
        path
      end
    end
  end
end
