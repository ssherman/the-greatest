# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # Tag / untag flow shared by the book and author endpoints. The including
        # controller defines `model_class`, `policy_class`. The rules themselves
        # (site match, merged categories, inherited rows) live in
        # Categories::ItemLinker; this only maps its result onto HTTP.
        # Root-anchor every ::Books:: / ::Categories:: reference in this namespace.
        module CategoryTaggable
          extend ActiveSupport::Concern
          include ::Api::V1::Admin::StrictIds

          NOT_ON_ITEM = "That item doesn't have that category."

          included do
            require_scope "books:admin:write"
          end

          # POST .../:id/categories {category_id}
          def create
            category_id = parse_id(params[:category_id])
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "category_id must be a positive integer")) if category_id.nil?

            change(category_id, :link)
          end

          # DELETE .../:id/categories/:category_id
          def destroy
            category_id = parse_id(params[:category_id])
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "category_id must be a positive integer")) if category_id.nil?

            change(category_id, :unlink)
          end

          private

          def change(category_id, action)
            noun = model_class.name.demodulize.downcase
            item = model_class.find_by(id: params[:id])
            return render_problem(::Api::Problem.new(:not_found, detail: "No #{noun} #{params[:id]}")) if item.nil?

            category = ::Category.find_by(id: category_id)
            return render_problem(::Api::Problem.new(:not_found, detail: "No category #{category_id}")) if category.nil?

            user = current_principal.user
            unless policy_class.new(user, item).update?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change this #{noun}"))
            end
            unless ::Books::CategoryPolicy.new(user, category).update?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not use this category"))
            end

            # Not in a transaction: the linker rescues RecordNotUnique itself.
            result = ::Categories::ItemLinker.public_send(action, item: item, category: category)
            unless result.success?
              message = result.errors.join(", ")
              code = (message == NOT_ON_ITEM) ? :not_found : :unprocessable
              return render_problem(::Api::Problem.new(code, detail: message))
            end

            log_change(action:, item:, category:)
            render json: {data: result.data.map { |link| link_entry(link) }}
          end

          def link_entry(link)
            category = link.category
            {id: category.id, slug: category.slug, name: category.name,
             category_type: category.category_type, source: link.source}
          end

          def log_change(action:, item:, category:)
            Rails.logger.info("event=api_admin_category_link action=#{action} token_id=#{current_principal.token.id} token_kind=#{current_principal.token_kind} " \
              "user_id=#{current_principal.user.id} item_type=#{item.class.name} item_id=#{item.id} category_id=#{category.id}")
          end
        end
      end
    end
  end
end
