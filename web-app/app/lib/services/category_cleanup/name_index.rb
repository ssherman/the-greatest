# frozen_string_literal: true

module Services
  module CategoryCleanup
    # The vocabulary of one category type as a run currently sees it: live books
    # categories, minus those a proposed or applied merge/retype/delete removes,
    # with proposed renames applied and merged-in link counts added to their
    # targets. The AI passes build prompts from it and resolve the model's
    # names back to category ids with #lookup.
    class NameIndex
      Entry = Struct.new(:category, :name, :links, keyword_init: true) do
        def id = category.id
      end

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

      def lookup(name)
        return nil if name.blank?

        key = NameNormalizer.twin_key(name)
        key && @by_key[key]
      end

      private

      def build
        categories = ::Books::Category.active
          .where(category_type: @category_type)
          .where.not(id: ::Books::Category.protected_ids)
          .to_a
        counts = ::CategoryItem.direct.joins(:category)
          .where(categories: {type: "Books::Category", category_type: @category_type, deleted: false})
          .group(:category_id).count
        decisions = ::CategoryCleanupDecision.for_run(@run).where(status: %i[proposed applied]).to_a
        removed = decisions.select { |d| d.action_merge? || d.action_retype? || d.action_delete? }.map(&:category_id).to_set
        renames = decisions.select(&:action_rename?).to_h { |d| [d.category_id, d.new_name] }

        links = categories.to_h { |c| [c.id, counts[c.id].to_i] }
        decisions.select(&:action_merge?).each do |d|
          links[d.target_category_id] += links[d.category_id].to_i if links.key?(d.target_category_id)
        end

        @entries = categories.reject { |c| removed.include?(c.id) }.map do |c|
          Entry.new(category: c, name: renames[c.id] || c.name, links: links[c.id])
        end
        index_names
      end

      # Effective names first, then original names, then alternative names;
      # within each tier the most-linked category wins a shared key. A name
      # with no alphanumerics has no key and is not indexed.
      def index_names
        @by_key = {}
        ordered = entries.sort_by { |entry| [-entry.links, entry.id] }
        ordered.each { |entry| add(entry.name, entry.id) }
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
