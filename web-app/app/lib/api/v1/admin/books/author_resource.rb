# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # The author as an admin search result. `params[:book_counts]` is the
        # page's {author_id => count} from one grouped query; an author with no
        # books has no key. Key order is the order in config/api/v1/admin_openapi.yaml.
        # Root-anchor every ::Books:: reference in this namespace.
        class AuthorResource
          include Alba::Resource

          attributes :id, :slug, :name, :kind, :provisional, :birth_year, :death_year

          attribute :rank do |author|
            author.primary_ranked_item&.rank
          end

          attribute :book_count do |author|
            params.fetch(:book_counts, {}).fetch(author.id, 0)
          end
        end
      end
    end
  end
end
