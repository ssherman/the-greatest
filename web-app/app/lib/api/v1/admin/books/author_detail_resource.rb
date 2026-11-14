# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One author with exactly the fields update_author takes, plus the names of
        # the fields an admin cleared on purpose. Key order is the order in
        # config/api/v1/admin_openapi.yaml.
        class AuthorDetailResource
          include Alba::Resource

          attributes :id, :slug, :name, :sort_name, :kind, :birth_year, :death_year,
            :exclude_from_rankings, :alternate_names, :provisional

          attribute :cleared_fields do |author|
            author.cleared_fields.map(&:field_name).sort
          end
        end
      end
    end
  end
end
