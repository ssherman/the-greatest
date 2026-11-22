# frozen_string_literal: true

module Api
  module V1
    module Books
      # A penalty as the public API presents it: what it is called, its
      # category and the reader-facing description. Never ids, values, the
      # agent-facing guidance or list flags. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      class PenaltyResource
        include Alba::Resource

        attributes :name, :category

        attribute :category_title do |penalty|
          ::Penalty.category_title(penalty.category)
        end

        attributes :description
      end
    end
  end
end
