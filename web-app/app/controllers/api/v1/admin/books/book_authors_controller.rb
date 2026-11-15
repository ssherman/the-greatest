# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST   /api/v1/admin/books/:id/authors             -- add an author to a book
        # PATCH  /api/v1/admin/books/:id/authors/:author_id  -- change role, position, credited_as
        # DELETE /api/v1/admin/books/:id/authors/:author_id  -- take the author off the book
        #
        # Rows are addressed by author id, as the book/author pair is unique. The rules
        # live in Services::Books::BookAuthors::Edit, which the admin page also calls.
        # The body is read raw so an explicit null survives, and a role that is not a
        # string is a 400 before the enum can raise. Root-anchor every ::Books:: reference.
        class BookAuthorsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scope "books:admin:write"

          FIELDS = %w[role position credited_as].freeze
          MAX_POSITION = 2_147_483_647

          def create
            book = find_book or return
            body = json_body
            return bad_body("The body must be a JSON object with author_id.") if body.nil?

            author_id = parse_id(body["author_id"])
            return bad_body("author_id must be a positive integer") if author_id.nil?

            unknown = body.keys - ["author_id"] - FIELDS
            return unknown_fields(unknown) if unknown.any?

            attrs = typed_attrs(body.slice(*FIELDS))
            finish(book, :add, author_id, ::Services::Books::BookAuthors::Edit.add(book: book, author_id: author_id, attrs: attrs))
          end

          def update
            book = find_book or return
            author_id = path_author_id or return
            body = json_body
            return bad_body("The body must be a JSON object with the fields to change.") if body.blank?

            unknown = body.keys - FIELDS
            return unknown_fields(unknown) if unknown.any?

            attrs = typed_attrs(body)
            finish(book, :update, author_id, ::Services::Books::BookAuthors::Edit.update(book: book, author_id: author_id, attrs: attrs))
          end

          def destroy
            book = find_book or return
            author_id = path_author_id or return
            finish(book, :remove, author_id, ::Services::Books::BookAuthors::Edit.remove(book: book, author_id: author_id))
          end

          private

          # The book, or nil after rendering a 404 / 403.
          def find_book
            book = ::Books::Book.find_by(id: params[:id])
            if book.nil?
              render_problem(::Api::Problem.new(:not_found, detail: "No book #{params[:id]}."))
              return nil
            end
            unless ::Books::BookPolicy.new(current_principal.user, book).update?
              render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change the authors of book #{book.id}."))
              return nil
            end

            book
          end

          # The :author_id path segment, or nil after rendering a 400 (the route
          # constraint lets "0" through).
          def path_author_id
            author_id = parse_id(params[:author_id])
            bad_body("author_id must be a positive integer") if author_id.nil?
            author_id
          end

          def finish(book, action, author_id, result)
            unless result.success?
              code = (result.code == :not_found) ? :not_found : :unprocessable
              detail = result.errors.join(", ")
              if action == :add && detail.include?("already on this book")
                detail = "Author #{author_id} is already on this book. Use update_book_author to change the role, position or credited_as."
              end
              return render_problem(::Api::Problem.new(code, detail: detail))
            end

            Rails.logger.info("event=api_admin_book_author action=#{action} token_id=#{current_principal.token.id} token_kind=#{current_principal.token_kind} " \
              "user_id=#{current_principal.user.id} book_id=#{book.id} author_id=#{author_id}")
            rows = book.book_authors.reload.includes(:author).sort_by { |row| [row.position || Float::INFINITY, row.id] }
            render json: {data: rows.map { |row| BookAuthorEntryResource.new(row).to_h }}
          end

          # Raises ::Api::Page::InvalidParameter (a 400) for a wrong JSON type.
          def typed_attrs(body)
            body.each_with_object({}) do |(key, value), attrs|
              attrs[key] = case key
              when "role"
                raise ::Api::Page::InvalidParameter, "role must be a string" unless value.is_a?(String)
                value
              when "position"
                valid = value.nil? || (value.is_a?(Integer) && value.between?(1, MAX_POSITION))
                unless valid
                  raise ::Api::Page::InvalidParameter, "position must be a positive integer or null"
                end
                value
              when "credited_as"
                raise ::Api::Page::InvalidParameter, "credited_as must be a string or null" unless value.nil? || value.is_a?(String)
                raise ::Api::Page::InvalidParameter, "credited_as must not contain a null byte" if value&.include?("\u0000")
                value
              end
            end
          end

          # The JSON object as sent. Not request.request_parameters: ParamsWrapper
          # would merge a copy of the body under a "book" key.
          def json_body
            parsed = JSON.parse(request.raw_post.to_s)
            parsed.is_a?(Hash) ? parsed : nil
          rescue JSON::ParserError
            nil
          end

          def unknown_fields(unknown)
            render_problem(::Api::Problem.new(:unprocessable,
              detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Editable fields: #{FIELDS.join(", ")}."))
          end

          def bad_body(detail)
            render_problem(::Api::Problem.new(:invalid_parameter, detail: detail))
          end
        end
      end
    end
  end
end
