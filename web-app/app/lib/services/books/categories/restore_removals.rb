# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Puts back the legacy links a run's judge removed: re-creates each as a
      # `legacy` link when its category is still active and the book does not
      # already hold it, then reconciles the touched books' ancestors once.
      # Dry run unless apply is true. Reads every row with the label, not only
      # the latest, so a rerun's removals are restored too.
      class RestoreRemovals
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(label:, apply: false)
          new(label: label, apply: apply).call
        end

        def initialize(label:, apply:)
          @label = label
          @apply = apply
        end

        def call
          if @label.blank?
            return Result.new(success?: false, data: {books: 0, links: 0, skipped: 0}, errors: ["a label is required"])
          end

          rows = ::Enrichment.where(kind: Judge::KIND).where("facts->>'label' = ?", @label)
            .where("jsonb_array_length(COALESCE(facts->'apply'->'removed', '[]'::jsonb)) > 0").order(:id).to_a
          removals = rows.flat_map do |row|
            Array(row.facts.dig("apply", "removed")).map { [row.enrichable_id, it["id"]] }
          end.uniq
          active = ::Books::Category.active.where(id: removals.map(&:last)).pluck(:id).to_set
          held = ::CategoryItem.where(item_type: "Books::Book", item_id: removals.map(&:first), category_id: removals.map(&:last))
            .pluck(:item_id, :category_id).to_set

          links = skipped = 0
          touched = []
          removals.each do |book_id, category_id|
            if !active.include?(category_id) || held.include?([book_id, category_id])
              skipped += 1
              next
            end
            links += 1
            touched << book_id
            next unless @apply

            ::CategoryItem.create!(item_type: "Books::Book", item_id: book_id, category_id: category_id, source: :legacy)
          end

          touched.uniq!
          ::Categories::AncestorReconciler.call(item_ids: touched) if @apply && touched.any?
          Result.new(success?: true, errors: [], data: {books: touched.size, links: links, skipped: skipped})
        end
      end
    end
  end
end
