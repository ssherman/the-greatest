# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/categories     -- search; q optional
        # GET /api/v1/admin/categories/:id -- detail, any status
        # POST /api/v1/admin/categories     -- create
        # PATCH /api/v1/admin/categories/:id -- edit (name, type, description, aliases, parent)
        #
        # Root-anchor every ::Books:: / ::Category reference in this namespace.
        class CategoriesController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read",
            create: "books:admin:write", update: "books:admin:write"

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
            relation = relation.where(category_type: type) if type
            relation = search(relation, query)

            render_page(relation, path: "/api/v1/admin/categories", query: {q: query, type: type, status: status}.compact) do |rows|
              counts = counts_for(rows.map(&:id))
              rows.map { |category| CategoryResource.new(category, params: counts).to_h }
            end
          end

          def show
            category = ::Books::Category.find(params[:id])

            render json: {data: CategoryResource.new(category, params: counts_for([category.id]), with_traits: :full).to_h}
          end

          def create
            category = ::Books::Category.new
            return render_forbidden unless ::Books::CategoryPolicy.new(current_principal.user, category).create?

            attributes = writable_attributes
            return if performed?

            save(category, attributes, status: :created)
          end

          def update
            category = ::Books::Category.find(params[:id])
            return render_forbidden unless ::Books::CategoryPolicy.new(current_principal.user, category).update?

            attributes = writable_attributes
            return if performed?
            if category.deleted?
              state = category.merged_into_id ? "merged" : "deleted"
              return render_problem(::Api::Problem.new(:unprocessable, detail: "This category is #{state} and cannot be edited"))
            end

            save(category, attributes, status: :ok)
          end

          private

          def render_forbidden
            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change categories"))
          end

          def save(category, attributes, status:)
            category.assign_attributes(attributes)
            twin = ::Categories::NameGuard.conflict(category)
            if twin
              kind = twin.name.casecmp?(category.name.to_s.strip) ? "name" : "alias"
              return render_problem(::Api::Problem.new(:unprocessable, detail: "Another category already uses that name: #{twin.id} (#{kind})"))
            end

            result = ::Categories::Editor.call(category: category, attributes: attributes)
            return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", "))) unless result.success?

            render status: status, json: {data: CategoryResource.new(category.reload, params: counts_for([category.id]), with_traits: :full).to_h}
          end

          # The keys present in the body, validated; unknown keys are ignored.
          # Renders the 400/422 itself (callers check performed?).
          def writable_attributes
            attributes = {}
            attributes[:name] = params[:name].to_s if params.key?(:name)
            attributes[:description] = params[:description]&.to_s if params.key?(:description)

            if params.key?(:category_type)
              type = params[:category_type].to_s
              return bad_parameter("category_type must be one of #{TYPES.join(", ")}") unless TYPES.include?(type)

              attributes[:category_type] = type
            end

            if params.key?(:alternative_names)
              names = params[:alternative_names]
              unless names.is_a?(Array) && names.all?(String)
                return bad_parameter("alternative_names must be an array of strings")
              end

              attributes[:alternative_names] = names.map(&:strip).reject(&:blank?)
            end

            if params.key?(:parent_id)
              if params[:parent_id].nil?
                attributes[:parent_id] = nil
              else
                parent_id = parse_id(params[:parent_id])
                return bad_parameter("parent_id must be a positive integer or null") if parent_id.nil?
                unless ::Books::Category.exists?(parent_id)
                  return render_problem(::Api::Problem.new(:unprocessable, detail: "No parent category #{parent_id}"))
                end

                attributes[:parent_id] = parent_id
              end
            end

            attributes
          end

          def bad_parameter(detail)
            render_problem(::Api::Problem.new(:invalid_parameter, detail: detail))
            nil
          end

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
              children: ::Category.where(parent_id: ids).group(:parent_id).count,
              ranked_books: ranked_counts(ids)
            }
          end

          # Ranked books on the primary configuration, as the public show counts them.
          def ranked_counts(ids)
            configuration = ::Books::RankingConfiguration.default_primary
            return {} unless configuration

            ::Books::RankedBooksQuery.counts_by_category(ranking_configuration: configuration, category_ids: ids)
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
