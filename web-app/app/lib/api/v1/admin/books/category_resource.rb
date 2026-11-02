# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # The category as an admin sees it: the public fields plus status, counts
        # and provenance. `parent` is the raw parent (a deleted or merged one
        # shows, unlike the public resource). `params` carries the page's grouped
        # counts: :book_links and :author_links ({category_id => n}) and :children
        # ({parent_id => n}); a missing key is 0. Key order here IS the order in
        # config/api/v1/admin_openapi.yaml. Root-anchor every ::Books:: reference.
        class CategoryResource
          include Alba::Resource

          attributes :id, :slug, :name, :category_type, :description

          attribute :parent do |category|
            parent = category.parent
            parent && {id: parent.id, slug: parent.slug, name: parent.name}
          end

          attributes :alternative_names, :deleted

          attribute :merged_into do |category|
            target = category.merged_into
            target && {id: target.id, name: target.name}
          end

          attributes :item_count

          attribute :book_link_count do |category|
            params.fetch(:book_links, {}).fetch(category.id, 0)
          end

          attribute :author_link_count do |category|
            params.fetch(:author_links, {}).fetch(category.id, 0)
          end

          attribute :children_count do |category|
            params.fetch(:children, {}).fetch(category.id, 0)
          end

          attributes :import_source, :created_at, :updated_at

          trait :full do
            attribute :children do |category|
              category.child_categories.order(:name, :id).map { |child| {id: child.id, slug: child.slug, name: child.name} }
            end

            attribute :ancestors do |category|
              if category.location?
                category.ancestors.reverse.map { |node| {id: node.id, slug: node.slug, name: node.name} }
              else
                []
              end
            end
          end
        end
      end
    end
  end
end
