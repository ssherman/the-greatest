# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/books/:id/identifiers    -- a book's identifiers and its editions'; scope=work for its own only
        # GET /api/v1/admin/authors/:id/identifiers  -- an author's identifiers
        # GET /api/v1/admin/identifiers?type=&value= -- every record holding that identifier
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class IdentifiersController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes book_index: "books:admin:read", author_index: "books:admin:read", lookup: "books:admin:read"

          IDENTIFIER_TYPES = ::Identifier.identifier_types.keys.grep(/\Abooks_/).freeze
          # What a book (work) or an author may hold when an admin writes one directly.
          BOOK_TYPES = IDENTIFIER_TYPES.grep(/\Abooks_work_/).freeze
          AUTHOR_TYPES = IDENTIFIER_TYPES.grep(/\Abooks_author_/).freeze
          VALUE_LIMIT = 255
          SCOPES = %w[work].freeze

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
            type = enum_param!(:type, IDENTIFIER_TYPES)
            raise ::Api::Page::InvalidParameter, "type is required" if type.nil?

            value = text_param!(:value, required: true, max_length: VALUE_LIMIT)
            found = IdentifierResource.preload(::Identifier.where(identifier_type: type, value: value).order(:id))

            render json: {data: found.filter_map { |identifier| IdentifierResource.holder_row(identifier) }}
          end

          private

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
