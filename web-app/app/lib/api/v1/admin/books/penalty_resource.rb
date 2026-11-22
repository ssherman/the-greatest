# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A penalty of the books catalogue. `params` carries :values
        # ({penalty_id => value on the default primary}) and :list_counts
        # ({penalty_id => books lists it is attached to}). Key order is the
        # order of AdminPenalty in config/api/v1/admin_openapi.yaml.
        class PenaltyResource
          include Alba::Resource

          attributes :id, :name, :type

          attribute :kind do |penalty|
            penalty.dynamic? ? "dynamic" : "static"
          end

          attribute :dynamic_type do |penalty|
            penalty.dynamic_type
          end

          attribute :driving_field do |penalty|
            penalty.driving_field
          end

          attribute :category do |penalty|
            penalty.category
          end

          attribute :category_title do |penalty|
            ::Penalty.category_title(penalty.category)
          end

          attributes :description, :guidance

          attribute :value_on_primary do |penalty|
            params[:values][penalty.id]
          end

          attribute :books_list_count do |penalty|
            params[:list_counts].fetch(penalty.id, 0)
          end
        end
      end
    end
  end
end
