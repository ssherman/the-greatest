# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET    /api/v1/admin/books/:id/descriptions    -- every description of a book
        # GET    /api/v1/admin/authors/:id/descriptions  -- every description of an author
        # POST   /api/v1/admin/{books|authors}/:id/descriptions {content, source, source_name?, source_url?, license?}
        # PATCH  /api/v1/admin/descriptions/:id          -- any subset of those fields
        # POST   /api/v1/admin/descriptions/:id/prefer
        # DELETE /api/v1/admin/descriptions/:id
        #
        # The writes are Services::Descriptions::AdminWrite, the same code the admin
        # page runs. The Wikipedia rule (a source_url is required, the license
        # defaults to CC BY-SA 4) is the API's alone; the page is unchanged.
        #
        # Descriptions are polymorphic; the record is looked up through ::Books::Book
        # or ::Books::Author first, and a description by id only when its describable
        # is one of those, so another domain's descriptions are never reachable here.
        # Root-anchor every ::Books:: reference in this namespace.
        class DescriptionsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes book_index: "books:admin:read", author_index: "books:admin:read",
            book_create: "books:admin:write", author_create: "books:admin:write",
            update: "books:admin:write", prefer: "books:admin:write", destroy: "books:admin:merge"

          WRITE = ::Services::Descriptions::AdminWrite
          CONTENT_LIMIT = ::Correction::MAX_TEXT_VALUE_LENGTH
          FIELD_LIMIT = 2000
          SOURCES = ::Description.sources.keys.freeze
          LICENSES = ::Description.licenses.keys.freeze
          POLICIES = {"Books::Book" => ::Books::BookPolicy, "Books::Author" => ::Books::AuthorPolicy}.freeze

          def book_index = list_for(::Books::Book, "book")

          def author_index = list_for(::Books::Author, "author")

          def book_create = add_for(::Books::Book, "book")

          def author_create = add_for(::Books::Author, "author")

          def update
            description = find_description
            return if performed?
            return forbidden unless policy_for(description).update?

            attrs = writable_attributes(creating: false, description: description)
            result = WRITE.update(description: description, attrs: attrs)
            return refuse(result) unless result.success?

            log_change("update", description, changed: description.saved_changes.keys - %w[updated_at])
            render_written(description)
          end

          def prefer
            description = find_description
            return if performed?
            return forbidden unless policy_for(description).update?

            WRITE.set_preferred(description: description)
            log_change("prefer", description)
            render_written(description)
          end

          def destroy
            description = find_description
            return if performed?
            return forbidden unless policy_for(description).destroy?

            WRITE.destroy(description: description)
            log_change("destroy", description)
            render_written(description)
          end

          private

          # Every kind and locale, in the order the admin page shows them. The shown
          # description is the public page's summary, picked by the same resolver
          # (preferred wins, else source priority; deprecated is never shown).
          def list_for(model, name)
            record = model.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No #{name} #{params[:id]}.")) unless record

            rows = record.descriptions.reorder(rank: :desc, source: :asc).to_a
            render json: {
              data: rows.map { |description| DescriptionResource.new(description).to_h },
              shown_description_id: ::Descriptions::Resolver.call(rows, kind: :summary)&.id
            }
          end

          def add_for(model, name)
            record = model.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No #{name} #{params[:id]}.")) unless record
            return forbidden unless POLICIES.fetch(model.name).new(current_principal.user, record).update?

            result = WRITE.create(describable: record, attrs: writable_attributes(creating: true))
            return refuse(result) unless result.success?

            log_change("create", result.data[:description])
            render_written(result.data[:description], status: :created)
          end

          # A description of a book or author only; anything else (music, games, no
          # such id) is a 404.
          def find_description
            id = parse_id(params[:id])
            description = id && ::Description.find_by(id: id, describable_type: POLICIES.keys)
            return description if description&.describable

            render_problem(::Api::Problem.new(:not_found, detail: "No description #{params[:id]}."))
            nil
          end

          def policy_for(description)
            POLICIES.fetch(description.describable_type).new(current_principal.user, description.describable)
          end

          # The keys present in the body, validated (a 400 via InvalidParameter). A
          # create requires content and source; an update takes any subset. When
          # the source is set to something other than `other` and no source_name is
          # sent, the old name is dropped, as the admin page does.
          def writable_attributes(creating:, description: nil)
            attrs = {}
            attrs["content"] = text_param!(:content, required: true, max_length: CONTENT_LIMIT) if creating || params.key?(:content)
            if creating || params.key?(:source)
              raise ::Api::Page::InvalidParameter, "source is required" if params[:source].nil?

              attrs["source"] = enum_param!(:source, SOURCES)
            end
            attrs["source_name"] = text_param!(:source_name, required: false, max_length: FIELD_LIMIT) if params.key?(:source_name)
            attrs["source_url"] = text_param!(:source_url, required: false, max_length: FIELD_LIMIT) if params.key?(:source_url)
            attrs["license"] = enum_param!(:license, LICENSES) if params.key?(:license)

            attrs["source_name"] = nil if attrs["source"] && attrs["source"] != "other" && !params.key?(:source_name)
            apply_wikipedia_rule(attrs, description)
            attrs
          end

          # A description that is (or becomes) wikipedia keeps its source_url: setting
          # the source to wikipedia needs one, and clearing it on an existing
          # wikipedia row is refused. A URL-less imported row still accepts other
          # edits, so a URL is not demanded when the body leaves it alone.
          def apply_wikipedia_rule(attrs, description)
            if attrs["source"] == "wikipedia"
              url = attrs.key?("source_url") ? attrs["source_url"] : description&.source_url
              raise ::Api::Page::InvalidParameter, "source_url is required when source is wikipedia" if url.blank?

              attrs["license"] = "cc_by_sa_4" unless attrs.key?("license") || description&.license
            elsif description&.source_wikipedia? && !attrs.key?("source") && attrs.key?("source_url") && attrs["source_url"].blank?
              raise ::Api::Page::InvalidParameter, "source_url is required when source is wikipedia"
            end
          end

          def render_written(description, status: :ok)
            render status: status, json: {
              data: DescriptionResource.new(description).to_h,
              shown_description_id: shown_id(description.describable)
            }
          end

          # What the public page shows for the record now: re-read, so a delete or
          # a prefer is reflected.
          def shown_id(record)
            ::Descriptions::Resolver.call(record.descriptions.reload.to_a, kind: :summary)&.id
          end

          def refuse(result)
            data = result.data
            if data[:code] == :conflict
              detail = "Another #{data[:description].source} description already exists (#{data[:existing_id]}); edit it instead."
              return render_problem(::Api::Problem.new(:unprocessable, detail: detail))
            end

            render_problem(::Api::Problem.new(:invalid_parameter, detail: result.errors.join(", ")))
          end

          def forbidden
            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change this record's descriptions."))
          end

          # Field names only, never the text.
          def log_change(action, description, **flags)
            extra = flags.map { |key, value| " #{key}=#{Array(value).join(",")}" }.join
            Rails.logger.info("event=api_admin_description action=#{action}#{extra} token_id=#{current_principal.token.id} " \
              "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} " \
              "record_type=#{description.describable_type} record_id=#{description.describable_id} description_id=#{description.id}")
          end
        end
      end
    end
  end
end
