# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET    /api/v1/admin/books/:id/identifiers    -- a book's identifiers and its editions'; scope=work for its own only
        # GET    /api/v1/admin/authors/:id/identifiers  -- an author's identifiers
        # GET    /api/v1/admin/identifiers?type=&value= -- every record holding that identifier
        # POST   /api/v1/admin/{books|authors}/:id/identifiers {identifier_type, value}
        # DELETE /api/v1/admin/{books|authors}/:id/identifiers/:identifier_id
        #
        # The rules for a write (types per record kind, value formats, an
        # author's one Wikidata/VIAF link, the enrichment re-run) live in
        # Services::Books::Identifiers::AdminWrite; this maps its result onto HTTP.
        # Root-anchor every ::Books:: reference in this namespace.
        class IdentifiersController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes book_index: "books:admin:read", author_index: "books:admin:read", lookup: "books:admin:read",
            book_create: "books:admin:write", author_create: "books:admin:write",
            book_destroy: "books:admin:merge", author_destroy: "books:admin:merge"

          WRITE = ::Services::Books::Identifiers::AdminWrite
          VALUE_LIMIT = WRITE::VALUE_LIMIT
          SCOPES = %w[work].freeze
          # The most holders find_by_identifier and `also_held_by` list.
          HOLDER_LIMIT = 100

          def book_index
            scope = enum_param!(:scope, SCOPES)
            book = find_record(::Books::Book, "book")
            return if performed?

            own = ::Identifier.where(identifiable: book)
            identifiers = if scope == "work"
              own.order(:id)
            else
              # Own rows first (their identifiable_id is constant), then each edition's
              # by edition id: one query however many editions, because some books hold
              # thousands of identifiers.
              edition_ids = ::Books::Edition.where(book_id: book.id).select(:id)
              own.or(::Identifier.where(identifiable_type: "Books::Edition", identifiable_id: edition_ids))
                .order(Arel.sql("(identifiable_type = 'Books::Edition')"), :identifiable_id, :id)
            end

            render_identifiers(identifiers, "/api/v1/admin/books/#{book.id}/identifiers", {scope: scope}.compact)
          end

          def author_index
            author = find_record(::Books::Author, "author")
            return if performed?

            render_identifiers(::Identifier.where(identifiable: author).order(:id),
              "/api/v1/admin/authors/#{author.id}/identifiers")
          end

          def lookup
            type = enum_param!(:type, WRITE::IDENTIFIER_TYPES)
            raise ::Api::Page::InvalidParameter, "type is required" if type.nil?

            value = text_param!(:value, required: true, max_length: VALUE_LIMIT)
            rows, truncated = holders(::Identifier.where(identifier_type: type, value: value))
            render json: {data: rows, truncated: truncated}
          end

          def book_create = add_identifier(::Books::Book, ::Books::BookPolicy)

          def author_create = add_identifier(::Books::Author, ::Books::AuthorPolicy)

          def book_destroy = remove_identifier(::Books::Book, ::Books::BookPolicy)

          def author_destroy = remove_identifier(::Books::Author, ::Books::AuthorPolicy)

          private

          def add_identifier(model, policy)
            type = text_param!(:identifier_type, required: true, max_length: VALUE_LIMIT)
            value = text_param!(:value, required: true, max_length: VALUE_LIMIT)
            record = find_record(model, noun(model))
            return if performed?
            return forbidden(model) unless policy.new(current_principal.user, record).update?

            result = WRITE.add(record: record, identifier_type: type, value: value)
            return refuse(result) unless result.success?

            identifier = result.data[:identifier]
            log_change("add", identifier, created: result.data[:created], promoted: result.data[:promoted])
            others, truncated = holders(::Identifier.where(identifier_type: identifier.identifier_type, value: identifier.value)
              .where.not(id: identifier.id))
            render json: {data: IdentifierResource.new(identifier).to_h, promoted: result.data[:promoted],
                          also_held_by: others, truncated: truncated},
              status: result.data[:created] ? :created : :ok
          end

          def remove_identifier(model, policy)
            record = find_record(model, noun(model))
            return if performed?

            identifier_id = parse_id(params[:identifier_id])
            identifier = identifier_id && ::Identifier.find_by(id: identifier_id, identifiable: record)
            if identifier.nil?
              return render_problem(::Api::Problem.new(:not_found,
                detail: "No identifier #{params[:identifier_id]} on #{noun(model)} #{record.id}."))
            end
            return forbidden(model) unless policy.new(current_principal.user, record).destroy?

            deleted = IdentifierResource.new(identifier).to_h
            WRITE.remove(record: record, identifier: identifier)
            log_change("remove", identifier)
            render json: {data: deleted}
          end

          # [holder rows, truncated?] for books holders only (the indexes lead
          # with identifiable_type), at most HOLDER_LIMIT of them.
          def holders(relation)
            found = relation.where(identifiable_type: ::Identifier::BOOKS_TYPES).order(:id).limit(HOLDER_LIMIT + 1).to_a
            truncated = found.size > HOLDER_LIMIT
            rows = IdentifierResource.preload(found.first(HOLDER_LIMIT))
            [rows.filter_map { |identifier| IdentifierResource.holder_row(identifier) }, truncated]
          end

          def refuse(result)
            code = (result.data[:code] == :invalid) ? :invalid_parameter : :unprocessable
            render_problem(::Api::Problem.new(code, detail: result.errors.join(", ")))
          end

          def forbidden(model)
            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change this #{noun(model)}'s identifiers."))
          end

          def noun(model) = model.name.demodulize.downcase

          def log_change(action, identifier, **flags)
            outcome = flags.map { |key, flag| " #{key}=#{flag}" }.join
            Rails.logger.info("event=api_admin_identifier action=#{action}#{outcome} token_id=#{current_principal.token.id} " \
              "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} " \
              "record_type=#{identifier.identifiable_type} record_id=#{identifier.identifiable_id} " \
              "identifier_id=#{identifier.id} identifier_type=#{identifier.identifier_type} value=#{identifier.value.inspect}")
          end

          def render_identifiers(identifiers, path, query = {})
            render_page(identifiers, path: path, query: query) do |rows|
              IdentifierResource.preload(rows).map { |identifier| IdentifierResource.new(identifier).to_h }
            end
          end

          def find_record(model, name)
            model.find_by(id: parse_id(params[:id])) || render_problem(
              ::Api::Problem.new(:not_found, detail: "No #{name} #{params[:id]}.")
            )
          end
        end
      end
    end
  end
end
