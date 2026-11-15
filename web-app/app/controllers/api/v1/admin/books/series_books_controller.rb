# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST   /api/v1/admin/series/:id/books           -- link a book to a series
        # PATCH  /api/v1/admin/series/:id/books/:book_id  -- change position, numbered, position_label
        # DELETE /api/v1/admin/series/:id/books/:book_id  -- unlink the book
        #
        # Rows are addressed by book id, as the series/book pair is unique. The rules live in
        # Services::Books::SeriesEdits::Membership, which the admin page also calls. Every
        # response is the whole series. Root-anchor every ::Books:: reference.
        class SeriesBooksController < BaseController
          include SeriesWrites

          require_scope "books:admin:write"

          FIELDS = %w[position numbered position_label].freeze

          def create
            series = find_series or return
            return render_forbidden unless allowed?(series)

            body = json_body
            return bad_body("The body must be a JSON object with book_id.") if body.nil?

            book_id = parse_id(body["book_id"])
            return bad_body("book_id must be a positive integer") if book_id.nil?

            unknown = body.keys - ["book_id"] - FIELDS
            return unknown_fields(unknown, ["book_id"] + FIELDS) if unknown.any?

            attrs = typed_attrs(body.slice(*FIELDS))
            finish(series, :add, book_id, ::Services::Books::SeriesEdits::Membership.add(series: series, book_id: book_id, attrs: attrs))
          end

          def update
            series = find_series or return
            return render_forbidden unless allowed?(series)

            book_id = path_book_id or return
            body = json_body
            return bad_body("The body must be a JSON object with the fields to change.") if body.blank?

            unknown = body.keys - FIELDS
            return unknown_fields(unknown, FIELDS) if unknown.any?

            attrs = typed_attrs(body)
            finish(series, :update, book_id, ::Services::Books::SeriesEdits::Membership.update(series: series, book_id: book_id, attrs: attrs))
          end

          def destroy
            series = find_series or return
            return render_forbidden unless allowed?(series)

            book_id = path_book_id or return
            finish(series, :remove, book_id, ::Services::Books::SeriesEdits::Membership.remove(series: series, book_id: book_id))
          end

          private

          def allowed?(series) = ::Books::SeriesPolicy.new(current_principal.user, series).update?

          # The :book_id path segment, or nil after rendering a 400 (the route constraint lets "0" through).
          def path_book_id
            book_id = parse_id(params[:book_id])
            bad_body("book_id must be a positive integer") if book_id.nil?
            book_id
          end

          def finish(series, action, book_id, result)
            return refuse(result) unless result.success?

            log_series("book_#{action}", series.id, " book_id=#{book_id}")
            render_series(series)
          end

          # Raises ::Api::Page::InvalidParameter (a 400) for a wrong JSON type.
          def typed_attrs(body)
            body.each_with_object({}) do |(key, value), attrs|
              attrs[key] = case key
              when "position" then typed_position!(value)
              when "numbered" then typed_boolean!(key, value)
              when "position_label" then typed_string!(key, value, nullable: true)
              end
            end
          end
        end
      end
    end
  end
end
