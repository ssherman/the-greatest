# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/categories     -- search; q optional
        # GET /api/v1/admin/categories/:id -- detail, any status
        # POST /api/v1/admin/categories     -- create
        # PATCH /api/v1/admin/categories/:id -- edit (name, type, description, aliases, parent)
        # POST /api/v1/admin/categories/:id/merge -- fold up to 50 sources into :id
        # DELETE /api/v1/admin/categories/:id -- soft delete (removes every link)
        #
        # Root-anchor every ::Books:: / ::Category reference in this namespace.
        class CategoriesController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read",
            create: "books:admin:write", update: "books:admin:write",
            merge: "books:admin:merge", destroy: "books:admin:merge"

          MAX_MERGE_SOURCES = 50

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

            persist_and_render(category, attributes, status: :created)
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

            persist_and_render(category, attributes, status: :ok)
          end

          # The target is the path category. Nothing merges until the body, every
          # record, the policy and the merger's own preconditions have passed for
          # ALL sources; a merge is permanent. Never wrap the loop in a
          # transaction: each merge manages its own and queues work after commit.
          def merge
            source_ids = parse_source_ids
            return if performed?

            dry_run = strict_dry_run
            return if dry_run == :invalid

            target = ::Books::Category.find_by(id: params[:id])
            return render_problem(::Api::Problem.new(:not_found, detail: "No target category #{params[:id]}")) if target.nil?

            sources = []
            source_ids.each do |id|
              source = ::Books::Category.find_by(id: id)
              return render_problem(::Api::Problem.new(:not_found, detail: "No source category #{id}")) if source.nil?

              sources << source
            end

            ([["target", target]] + sources.map { |source| ["source", source] }).each do |role, record|
              next if ::Books::CategoryPolicy.new(current_principal.user, record).destroy?

              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete the #{role} category #{record.id}"))
            end

            refused = sources.filter_map do |source|
              message = ::Categories::Merger.refusal(source: source, target: target)
              "#{source.id}: #{message}" if message
            end
            return render_problem(::Api::Problem.new(:unprocessable, detail: refused.join("; "))) if refused.any?

            return render_merge_dry_run(target, sources) if dry_run

            run_merges(target, sources)
          end

          def destroy
            dry_run = strict_dry_run
            return if dry_run == :invalid

            category = ::Books::Category.find(params[:id])
            unless ::Books::CategoryPolicy.new(current_principal.user, category).destroy?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete category #{category.id}"))
            end
            return render_problem(::Api::Problem.new(:unprocessable, detail: "Category #{category.id} is already deleted")) if category.deleted?

            refusal = ::Categories::Deleter.refusal(category: category)
            return render_problem(::Api::Problem.new(:unprocessable, detail: refusal)) if refusal

            counts = counts_for([category.id])
            removed = {
              book_links_removed: counts[:book_links].fetch(category.id, 0),
              author_links_removed: counts[:author_links].fetch(category.id, 0)
            }
            unless dry_run
              begin
                ::Categories::Deleter.new(category: category, soft: true).delete
              rescue ::Categories::Refused => e
                return render_problem(::Api::Problem.new(:unprocessable, detail: e.message))
              end
              log_delete(category, removed)
              category.reload
            end

            render json: {
              data: {category: CategoryResource.new(category, params: counts_for([category.id])).to_h, **removed},
              meta: {dry_run: dry_run}
            }
          end

          private

          # 1..50 strict, distinct ids that do not include the target. Renders
          # the 400 itself and returns nil (callers check performed?).
          def parse_source_ids
            raw = params[:source_ids]
            unless raw.is_a?(Array) && raw.size.between?(1, MAX_MERGE_SOURCES)
              return bad_parameter("source_ids must be an array of 1 to #{MAX_MERGE_SOURCES} ids")
            end

            ids = raw.map { |value| parse_id(value) }
            return bad_parameter("source_ids must be positive integers") if ids.any?(&:nil?)
            return bad_parameter("source_ids must not repeat an id") if ids.uniq.size != ids.size
            return bad_parameter("source_ids must not include the target category") if ids.include?(params[:id].to_i)

            ids
          end

          def render_merge_dry_run(target, sources)
            ids = sources.map(&:id)
            book_links = link_counts("Books::Book", ids)
            author_links = link_counts("Books::Author", ids)
            render json: {
              data: {
                target: CategoryResource.new(target, params: counts_for([target.id])).to_h,
                sources: sources.map do |source|
                  {
                    id: source.id,
                    name: source.name,
                    book_link_count: book_links.fetch(source.id, 0),
                    author_link_count: author_links.fetch(source.id, 0)
                  }
                end
              },
              meta: {dry_run: true}
            }
          end

          # A merge commits before its post-commit work (reindex queueing, ancestor
          # reconcile) runs, so an exception can arrive after the source is already
          # merged. Re-read the row: a merged source is reported as merged, with the
          # error listed apart; only a merge that did not happen stops the batch.
          def run_merges(target, sources)
            merged = []
            post_commit_errors = []
            sources.each_with_index do |source, index|
              ::Categories::Merger.new(category: source, category_to_merge_with: target).merge
              log_merge(source, target, "succeeded")
              merged << source.id
            rescue => e
              if committed_merge?(source, target)
                log_merge(source, target, "succeeded", post_commit_error: e.message)
                merged << source.id
                post_commit_errors << {id: source.id, message: e.message}
                next
              end

              log_merge(source, target, "failed", error: e.message)
              body = ::Api::Problem.new(:unprocessable, detail: "Merged #{merged.size} of #{sources.size}; #{source.id} failed: #{e.message}").to_h
              body.merge!(merged: merged, failed: {id: source.id, message: e.message}, not_attempted: sources[(index + 1)..].map(&:id))
              body[:post_commit_errors] = post_commit_errors if post_commit_errors.any?
              return render(json: body, status: :unprocessable_entity, content_type: ::Api::Problem::CONTENT_TYPE)
            end

            target.reload
            data = {target: CategoryResource.new(target, params: counts_for([target.id])).to_h, merged: merged}
            data[:post_commit_errors] = post_commit_errors if post_commit_errors.any?
            render json: {data: data, meta: {dry_run: false}}
          end

          def committed_merge?(source, target)
            source.reload
            source.deleted? && source.merged_into_id == target.id
          rescue
            false
          end

          # absent -> false; true/"true" -> true; false/"false" -> false; anything
          # else renders a 400 and returns :invalid.
          def strict_dry_run
            return false unless params.key?(:dry_run)

            case params[:dry_run]
            when true, "true" then true
            when false, "false" then false
            else
              bad_parameter("dry_run must be true or false")
              :invalid
            end
          end

          def log_merge(source, target, outcome, error: nil, post_commit_error: nil)
            line = "event=api_admin_category_merge outcome=#{outcome} #{log_actor} source_id=#{source.id} target_id=#{target.id}"
            line += " errors=#{error.inspect}" if error
            line += " post_commit_error=#{post_commit_error.inspect}" if post_commit_error
            Rails.logger.info(line)
          end

          def log_delete(category, removed)
            Rails.logger.info("event=api_admin_category_delete outcome=succeeded #{log_actor} category_id=#{category.id} " \
              "book_links_removed=#{removed[:book_links_removed]} author_links_removed=#{removed[:author_links_removed]}")
          end

          def log_actor
            "token_id=#{current_principal.token.id} user_id=#{current_principal.user.id}"
          end

          def render_forbidden
            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change categories"))
          end

          def persist_and_render(category, attributes, status:)
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
            if params.key?(:name)
              return bad_parameter("name must be a string") unless params[:name].is_a?(String)

              attributes[:name] = params[:name].strip
            end
            if params.key?(:description)
              unless params[:description].nil? || params[:description].is_a?(String)
                return bad_parameter("description must be a string or null")
              end

              attributes[:description] = params[:description]
            end
            return bad_parameter("name is required") if creating? && attributes[:name].blank?

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

          def creating? = action_name == "create"

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
