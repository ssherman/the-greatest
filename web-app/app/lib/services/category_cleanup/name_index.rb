# frozen_string_literal: true

module Services
  module CategoryCleanup
    # The vocabulary of one category type as a run currently sees it: live books
    # categories, minus those a proposed merge/retype/delete removes, with
    # proposed renames applied and merged-in link counts added to their targets.
    # Applied decisions are already in the database, so only proposed ones are read. The AI passes build prompts from it and resolve the model's
    # names back to category ids with #lookup.
    class NameIndex
      # links is the effective count (merged-in links added); own_links is the
      # category's own direct count and decides its head/tail tier.
      Entry = Struct.new(:category, :name, :links, :own_links, keyword_init: true) do
        def id = category.id
      end

      CATEGORY_COLUMNS = (%w[id alternative_names] + ::CategoryCleanupDecision::SNAPSHOT_FIELDS).uniq.freeze

      def initialize(run:, category_type:)
        @run = run
        @category_type = category_type.to_s
        build
      end

      attr_reader :entries

      def head_names
        min = Rails.configuration.x.categories_cleanup.head_min_links
        entries.select { |entry| entry.links >= min }.sort_by { |entry| [-entry.links, entry.name] }.map(&:name)
      end

      # effective_only: match only the names categories will carry after the
      # proposed renames; a name a category is being renamed away from is free.
      def lookup(name, effective_only: false)
        return nil if name.blank?

        key = NameNormalizer.twin_key(name)
        key && (effective_only ? @effective_by_key : @by_key)[key]
      end

      private

      def build
        categories = ::Books::Category.active
          .where(category_type: @category_type)
          .where.not(id: ::Books::Category.protected_ids)
          .select(*CATEGORY_COLUMNS)
          .to_a
        counts = ::CategoryItem.direct.joins(:category)
          .where(categories: {type: "Books::Category", category_type: @category_type, deleted: false})
          .group(:category_id).count
        type_ids = ::Books::Category.where(category_type: @category_type).select(:id)
        decisions = ::CategoryCleanupDecision.for_run(@run).where(status: :proposed, category_id: type_ids)
          .order(:id).pluck(:category_id, :action, :new_name, :target_category_id)
        removed = decisions.select { |row| %w[merge retype delete].include?(row[1]) }.map(&:first).to_set
        renames = decisions.select { |row| row[1] == "rename" }.to_h { |row| [row[0], row[2]] }

        links = categories.to_h { |c| [c.id, counts[c.id].to_i] }
        decisions.select { |row| row[1] == "merge" }.each do |id, _, _, target_id|
          links[target_id] += links[id].to_i if links.key?(target_id)
        end

        @entries = categories.reject { |c| removed.include?(c.id) }.map do |c|
          Entry.new(category: c, name: renames[c.id] || c.name, links: links[c.id], own_links: counts[c.id].to_i)
        end
        index_names
      end

      # Effective names first, then original names, then alternative names;
      # within each tier the most-linked category wins a shared key. A name
      # with no alphanumerics has no key and is not indexed.
      def index_names
        @by_key = {}
        @effective_by_key = {}
        ordered = entries.sort_by { |entry| [-entry.links, entry.id] }
        ordered.each do |entry|
          add(entry.name, entry.id)
          key = NameNormalizer.twin_key(entry.name)
          @effective_by_key[key] ||= entry.id if key
        end
        ordered.each { |entry| add(entry.category.name, entry.id) }
        ordered.each do |entry|
          entry.category.alternative_names.each { |alt| add(alt, entry.id) }
        end
      end

      def add(name, id)
        key = NameNormalizer.twin_key(name)
        @by_key[key] ||= id if key
      end
    end
  end
end
