# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/categories     -- search; q optional
        # GET /api/v1/admin/categories/:id -- detail, any status
        #
        # Root-anchor every ::Books:: / ::Category reference in this namespace.
        class CategoriesController < BaseController
          STATUSES = %w[active deleted merged all].freeze

          # The Category enum also holds music and game types; these are the ones
          # a books category can have.
          TYPES = %w[genre location subject theme audience].freeze

          def index
            type = param_in(:type, TYPES)
            return if performed?
            status = param_in(:status, STATUSES) || "active"
            return if performed?
            query = params[:q].to_s.strip.presence

            relation = scoped_by_status(status).includes(:parent, :merged_into)
            relation = relation.where(category_type: ::Category.category_types.fetch(type)) if type
            relation = search(relation, query)

            render_page(relation, path: "/api/v1/admin/categories", query: {q: query, type: type, status: status}.compact) do |rows|
              rows.map { |category| CategoryResource.new(category, params: counts_for(rows.map(&:id))).to_h }
            end
          end

          def show
            category = ::Books::Category.find(params[:id])

            render json: {data: CategoryResource.new(category, params: counts_for([category.id]), with_traits: :full).to_h}
          end

          private

          def scoped_by_status(status)
            scope = ::Books::Category.all
            case status
            when "active" then scope.active
            when "deleted" then scope.soft_deleted.where(merged_into_id: nil)
            when "merged" then scope.merged
            else scope
            end
          end

          def search(relation, query)
            return relation.order(:name, :id) unless query

            escaped = ::Books::Category.sanitize_sql_like(query)
            relation
              .where(::CategorySearchQuery::NAME_OR_ALIAS_SQL, pattern: "%#{escaped}%")
              .order(Arel.sql(::Books::BrowseQuery.name_match_quality_sql(query, escaped)), :name, :id)
          end

          # The page's link and children counts: one grouped query each.
          def counts_for(ids)
            {
              book_links: link_counts("Books::Book", ids),
              author_links: link_counts("Books::Author", ids),
              children: ::Category.where(parent_id: ids).group(:parent_id).count
            }
          end

          def link_counts(item_type, ids)
            ::CategoryItem.where(category_id: ids, item_type: item_type).group(:category_id).count
          end

          # An absent param is nil; a value outside `allowed` renders the 400
          # (callers check performed?).
          def param_in(name, allowed)
            value = params[name]
            return nil if value.nil?
            return value.to_s if allowed.include?(value.to_s)

            render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be one of #{allowed.join(", ")}"))
            nil
          end
        end
      end
    end
  end
end
