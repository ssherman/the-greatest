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
          existing = ::CategoryItem.where(item_type: "Books::Book", item_id: removals.map(&:first), category_id: removals.map(&:last))
            .index_by { [it.item_id, it.category_id] }

          links = skipped = 0
          touched = []
          ActiveRecord::Base.transaction do
            removals.each do |book_id, category_id|
              item = existing[[book_id, category_id]]
              # An inherited row is not the book's own link: it is upgraded to legacy.
              if !active.include?(category_id) || (item && !item.source_inherited?)
                skipped += 1
                next
              end
              links += 1
              touched << book_id
              next unless @apply

              if item
                item.update!(source: :legacy)
              else
                ::CategoryItem.create!(item_type: "Books::Book", item_id: book_id, category_id: category_id, source: :legacy)
              end
            end

            touched.uniq!
            ::Categories::AncestorReconciler.call(item_ids: touched) if @apply && touched.any?
          end
          Result.new(success?: true, errors: [], data: {books: touched.size, links: links, skipped: skipped})
        end
      end
    end
  end
end
