# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/series     -- list; deleted series hidden unless include_deleted=true
        # GET /api/v1/admin/series/:id -- detail with books, any status
        # POST /api/v1/admin/series -- create
        # PATCH /api/v1/admin/series/:id -- rename, set the representative book or Goodreads id
        # DELETE /api/v1/admin/series/:id -- soft delete (removes every book link)
        # POST /api/v1/admin/series/:id/merge -- fold up to 50 sources into :id
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class SeriesController < BaseController
          include SeriesWrites

          require_scopes index: "books:admin:read", show: "books:admin:read",
            create: "books:admin:write", update: "books:admin:write",
            merge: "books:admin:merge", destroy: "books:admin:merge"

          MAX_MERGE_SOURCES = 50
          CREATE_FIELDS = %w[title goodreads_series_id].freeze
          UPDATE_FIELDS = %w[title representative_book_id goodreads_series_id].freeze

          SORTS = %w[title book_count].freeze

          BOOK_COUNT_SQL = "(SELECT COUNT(*) FROM books_series_books WHERE books_series_books.series_id = books_series.id)"

          def index
            sort = param_in(:sort, SORTS) || "title"
            return if performed?
            include_deleted = strict_boolean(:include_deleted)
            return if performed?
            min_books = non_negative_integer(:min_books)
            return if performed?
            max_books = non_negative_integer(:max_books)
            return if performed?
            query = params[:q].to_s.strip.presence

            relation = include_deleted ? ::Books::Series.all : ::Books::Series.active
            if query
              relation = relation.where("books_series.title ILIKE ?", "%#{::Books::Series.sanitize_sql_like(query)}%")
            end
            relation = relation.where("#{BOOK_COUNT_SQL} >= ?", min_books) if min_books
            relation = relation.where("#{BOOK_COUNT_SQL} <= ?", max_books) if max_books
            relation = if sort == "book_count"
              relation.order(Arel.sql("#{BOOK_COUNT_SQL} DESC"), :id)
            else
              relation.order(:title, :id)
            end

            echoed = {q: query, sort: (sort unless sort == "title"), include_deleted: (true if include_deleted),
                      min_books: min_books, max_books: max_books}.compact
            render_page(relation, path: "/api/v1/admin/series", query: echoed) do |rows|
              ids = rows.map(&:id)
              lookups = {
                counts: ::Books::SeriesBook.where(series_id: ids).group(:series_id).count,
                goodreads: ::Identifier.where(identifiable_type: "Books::Series", identifiable_id: ids,
                  identifier_type: :books_series_goodreads_id).pluck(:identifiable_id, :value).to_h
              }
              rows.map { |series| SeriesResource.new(series, params: lookups).to_h }
            end
          end

          def show
            series = ::Books::Series.includes(:representative_book, :identifiers).find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No series #{params[:id]}.")) unless series

            render json: {data: SeriesDetailResource.new(series).to_h}
          end

          def create
            return render_forbidden unless ::Books::SeriesPolicy.new(current_principal.user, ::Books::Series.new).create?

            body = json_body
            return bad_body("The body must be a JSON object with title.") if body.nil?

            unknown = body.keys - CREATE_FIELDS
            return unknown_fields(unknown, CREATE_FIELDS) if unknown.any?
            return bad_body("title is required") unless body.key?("title")

            result = ::Services::Books::SeriesEdits::Create.call(attrs: typed_attrs(body))
            return refuse(result) unless result.success?

            log_series("create", result.data.id)
            render_series(result.data, status: :created)
          end

          def update
            series = find_series or return
            return render_forbidden unless ::Books::SeriesPolicy.new(current_principal.user, series).update?

            body = json_body
            return bad_body("The body must be a JSON object with the fields to change.") if body.blank?

            unknown = body.keys - UPDATE_FIELDS
            return unknown_fields(unknown, UPDATE_FIELDS) if unknown.any?

            result = ::Services::Books::SeriesEdits::Update.call(series: series, attrs: typed_attrs(body))
            return refuse(result) unless result.success?

            log_series("update", series.id, " changed=#{body.keys.sort.join(",")}")
            render_series(series)
          end

          def destroy
            dry_run = strict_boolean(:dry_run)
            return if performed?

            series = find_series or return
            unless ::Books::SeriesPolicy.new(current_principal.user, series).destroy?
              return render_forbidden("Your account may not delete series #{series.id}.")
            end

            result = ::Services::Books::SeriesEdits::Delete.call(series: series, dry_run: dry_run)
            return refuse(result) unless result.success?

            book_count = result.data[:book_count]
            log_series("delete", series.id, " book_count=#{book_count}") unless dry_run
            body = {data: {id: series.id, deleted: true, book_count: book_count}}
            body[:meta] = {dry_run: true} if dry_run
            render json: body
          end

          # The target is the path series. Nothing merges until the body, every record,
          # the policy and each pair's preconditions have passed; a merge cannot be undone.
          def merge
            body = json_body
            return bad_body("The body must be a JSON object with source_ids.") if body.nil?

            unknown = body.keys - %w[source_ids dry_run]
            return unknown_fields(unknown, %w[source_ids dry_run]) if unknown.any?

            source_ids = parse_source_ids(body["source_ids"])
            return if performed?

            dry_run = body_dry_run(body)
            return if performed?

            target = ::Books::Series.find_by(id: params[:id])
            return render_problem(::Api::Problem.new(:not_found, detail: "No target series #{params[:id]}.")) unless target

            sources = []
            source_ids.each do |id|
              source = ::Books::Series.find_by(id: id)
              return render_problem(::Api::Problem.new(:not_found, detail: "No source series #{id}.")) unless source

              sources << source
            end

            ([["target", target]] + sources.map { |source| ["source", source] }).each do |role, record|
              next if ::Books::SeriesPolicy.new(current_principal.user, record).destroy?

              return render_forbidden("Your account may not delete the #{role} series #{record.id}.")
            end

            refused = sources.filter_map do |source|
              message = ::Services::Books::SeriesEdits::Merge.refusal(source: source, target: target)
              "#{source.id}: #{message}" if message
            end
            return render_problem(::Api::Problem.new(:unprocessable, detail: refused.join("; "))) if refused.any?

            run_merges(target, sources, dry_run)
          end

          private

          def typed_attrs(body)
            body.each_with_object({}) do |(key, value), attrs|
              attrs[key] = case key
              when "title", "goodreads_series_id"
                typed_string!(key, value)
              when "representative_book_id"
                if !value.nil? && !(value.is_a?(Integer) && value >= 1)
                  raise ::Api::Page::InvalidParameter, "representative_book_id must be a positive integer or null"
                end
                value
              end
            end
          end

          # 1..50 distinct positive integers that do not include the target. Renders the 400
          # itself and returns nil (callers check performed?).
          def parse_source_ids(raw)
            unless raw.is_a?(Array) && raw.size.between?(1, MAX_MERGE_SOURCES)
              return bad_body("source_ids must be an array of 1 to #{MAX_MERGE_SOURCES} ids")
            end

            ids = raw.map { |value| parse_id(value) }
            return bad_body("source_ids must be positive integers") if ids.any?(&:nil?)
            return bad_body("source_ids must not repeat an id") if ids.uniq.size != ids.size
            return bad_body("source_ids must not include the target series") if ids.include?(params[:id].to_i)

            ids
          end

          def body_dry_run(body)
            return false unless body.key?("dry_run")

            case body["dry_run"]
            when true, "true" then true
            when false, "false" then false
            else bad_body("dry_run must be true or false")
            end
          end

          # One source at a time, in order. A refusal that slips past the pre-checks (a
          # concurrent change) stops the batch; the sources already merged stay merged.
          # A dry run runs the real merges inside a transaction and rolls it back, so its
          # counts are exactly what a real merge would report, sources that share books
          # with each other included. Merge has no callbacks or enqueues to undo.
          def run_merges(target, sources, dry_run)
            outcome = nil
            ::Books::Series.transaction do
              outcome = merge_in_order(target, sources, dry_run)
              raise ActiveRecord::Rollback if dry_run
            end
            return render(json: outcome[:failure], status: :unprocessable_entity, content_type: ::Api::Problem::CONTENT_TYPE) if outcome[:failure]

            body = {data: {target: outcome[:target], sources: outcome[:rows]}}
            body[:meta] = {dry_run: true} if dry_run
            render json: body
          end

          def merge_in_order(target, sources, dry_run)
            rows = []
            sources.each_with_index do |source, index|
              result = ::Services::Books::SeriesEdits::Merge.call(target: target, source: source)

              unless result.success?
                Rails.logger.info("event=api_admin_series_merge outcome=failed token_id=#{current_principal.token.id} " \
                  "user_id=#{current_principal.user.id} source_id=#{source.id} target_id=#{target.id}")
                message = result.errors.join(", ")
                body = ::Api::Problem.new(:unprocessable, detail: "Merged #{rows.size} of #{sources.size}; #{source.id} failed: #{message}").to_h
                body.merge!(merged: rows.map { |row| row[:id] }, failed: {id: source.id, message: message},
                  not_attempted: sources[(index + 1)..].map(&:id))
                return {failure: body}
              end

              moved, dropped = result.data.values_at(:moved, :dropped)
              log_series("merge", source.id, " target_id=#{target.id} moved=#{moved} dropped=#{dropped}") unless dry_run
              rows << {id: source.id, title: source.title, moved: moved, dropped: dropped}
            end

            {rows: rows, target: SeriesDetailResource.new(::Books::Series.find(target.id)).to_h}
          end

          def param_in(name, allowed)
            value = params[name]
            return nil if value.nil?
            return value.to_s if allowed.include?(value.to_s)

            render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be one of #{allowed.join(", ")}"))
            nil
          end

          def strict_boolean(name)
            return false unless params.key?(name)

            case params[name]
            when true, "true" then true
            when false, "false" then false
            else
              render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be true or false"))
              nil
            end
          end

          def non_negative_integer(name)
            return nil unless params.key?(name)

            value = params[name].to_s
            unless value.match?(/\A\d{1,9}\z/)
              render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be a non-negative integer"))
              return nil
            end

            value.to_i
          end
        end
      end
    end
  end
end
