# frozen_string_literal: true

module Api
  module V1
    module Books
      module My
        # GET /api/v1/my/lists -- the token holder's own books lists, in the
        # site's /my/lists order: the four defaults, then custom lists by name.
        # POST creates a custom list (optionally with books), PATCH edits one and
        # DELETE removes a custom one. Order of refusals: body (400), list (404),
        # rules (422), books (404), budget (429), service (422).
        #
        # Every model reference is root-anchored (::Books::…): inside this module
        # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
        class ListsController < BaseController
          include ::Api::Library

          require_scopes index: "books:library:read", create: "books:library:write",
            update: "books:library:write", destroy: "books:library:write"

          CREATE_FIELDS = %w[name description public books].freeze
          UPDATE_FIELDS = %w[name description public].freeze

          def index
            # A member from before a default existed (or a new one) has no
            # reading/want_to_read list yet; creating them here is what the site does.
            relation = library_user.user_lists.where(type: "Books::UserList")
            ::Services::UserLists::EnsureDefaults.call(user: library_user, domain: :books, existing: relation.to_a)

            render_page(relation.order(Arel.sql(::Api::Library::LISTS_ORDER)), path: "/api/v1/my/lists") do |lists|
              counts = book_count_for(lists)
              lists.map { |list| UserListResource.new(list, params: {book_count: counts.fetch(list.id, 0)}).to_h }
            end
          end

          # POST /api/v1/my/lists  {name, description?, public?, books?}
          # With books the list and its books are one unit: a refused batch
          # leaves no list behind and costs no budget.
          def create
            body = json_body
            return bad_body("The body must be a JSON object with name.") if body.nil?

            name = name!(body["name"]) or return
            attrs = {name: name}
            if body.key?("description")
              attrs[:description] = description!(body["description"])
              return if performed?
            end
            if !body["public"].nil?
              attrs[:public] = public!(body["public"])
              return if performed?
            end
            slugs = nil
            if !body["books"].nil?
              return bad_body("books must be an array of book slugs") unless body["books"].is_a?(Array)

              slugs = book_slugs!(body["books"]) or return
            end
            unknown = body.keys - CREATE_FIELDS
            return unknown_fields(unknown, CREATE_FIELDS) if unknown.any?
            return refuse(cap_detail) if custom_cap_reached?

            books = slugs && (catalog_books!(slugs) or return)
            return create_list(attrs, nil) if books.nil?

            with_budget(books.size) { create_list(attrs, books) }
          end

          # PATCH /api/v1/my/lists/:list  {name?, description?, public?}
          def update
            body = json_body
            return bad_body("The body must be a JSON object with name, description and/or public.") if body.nil? || body.empty?

            attrs = {}
            if body.key?("name")
              attrs[:name] = name!(body["name"])
              return if performed?
            end
            if body.key?("description")
              attrs[:description] = description!(body["description"])
              return if performed?
            end
            if body.key?("public")
              attrs[:public] = public!(body["public"])
              return if performed?
            end

            list = find_my_list!(params[:list]) or return
            unknown = body.keys - UPDATE_FIELDS
            return unknown_fields(unknown, UPDATE_FIELDS) if unknown.any?
            result = ::Services::UserLists::UpdateList.call(list: list, attrs: attrs)
            return refuse(result.errors.first) unless result.success?

            render json: {data: list_json(list)}
          end

          # DELETE /api/v1/my/lists/:list -- no budget: it is one list, not book changes.
          def destroy
            list = find_my_list!(params[:list]) or return
            body = list_json(list)
            result = ::Services::UserLists::DeleteList.call(list: list)
            return refuse(result.errors.first) unless result.success?

            render json: {data: body}
          end

          private

          def refuse(detail)
            render_problem(::Api::Problem.new(:unprocessable, detail: detail))
          end

          # The Rails default list type for books is a custom list; the count is
          # of this member's own books lists only.
          def custom_list_count
            library_user.user_lists.where(type: "Books::UserList", list_type: ::Books::UserList.list_types.fetch("custom")).count
          end

          def cap_detail
            "You already have #{Rails.application.config.x.api.max_custom_lists} custom lists, the most allowed. Delete one first."
          end

          def custom_cap_reached?
            custom_list_count >= Rails.application.config.x.api.max_custom_lists
          end

          def list_json(list)
            ::Api::V1::Books::UserListResource.new(list, params: {book_count: book_count_for([list]).fetch(list.id, 0)}).to_h
          end

          # Valid, stripped name; else renders a 400 and returns nil.
          def name!(raw)
            name = ::Services::UserLists::ListRules.normalize_name(raw)
            bad_body("name must be a string of 1 to #{::Services::UserLists::ListRules::NAME_MAX} characters") if name.nil?
            name
          end

          # A string of up to 1,000 characters, or null to clear it. Blank is stored
          # as null. Renders a 400 on anything else (the caller checks `performed?`).
          def description!(raw)
            text = ::Services::UserLists::ListRules.normalize_description(raw)
            return text unless text == :invalid

            bad_body("description must be a string of up to #{::Services::UserLists::ListRules::DESCRIPTION_MAX} characters, or null")
            nil
          end

          # Only a JSON boolean: "yes" and "true" are rejected, not cast.
          def public!(raw)
            return raw if raw == true || raw == false

            bad_body("public must be true or false")
            nil
          end

          # Creates the list, and the books on it, in one transaction under the
          # owner lock (which also settles two racing creates against the cap).
          # Renders 201, or a 422 after rolling everything back.
          def create_list(attrs, books)
            list = nil
            problem = nil
            results = []
            ::Services::UserLists::OwnerMutation.call(owner: library_user) do
              if custom_cap_reached?
                problem = cap_detail
                raise ActiveRecord::Rollback
              end

              created = ::Services::UserLists::CreateList.call(user: library_user, klass: ::Books::UserList, **attrs)
              unless created.success?
                problem = created.errors.join(", ")
                raise ActiveRecord::Rollback
              end
              list = created.data.fetch(:list)
              if books
                result = ::Services::UserLists::AddItems.call(user_list: list, listables: books)
                unless result.success?
                  problem = result.errors.join(", ")
                  raise ActiveRecord::Rollback
                end
                results = result.data.fetch(:outcomes)
              end
            end
            return refuse(problem) if problem

            list.reload
            render status: :created, json: {
              data: list_json(list),
              meta: {
                results: results.map { |outcome| {book: outcome[:listable].slug, outcome: outcome[:outcome]} },
                library_changes_remaining: ::Services::Api::LibraryBudget.remaining(library_user, now: @library_now || Time.current)
              }
            }
          end
        end
      end
    end
  end
end
