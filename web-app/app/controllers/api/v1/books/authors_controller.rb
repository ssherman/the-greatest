# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/authors        -- the primary author ranking, best first, paginated
      # GET /api/v1/authors/:slug  -- one author, full shape; books are NOT embedded (spec D13)
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class AuthorsController < BaseController
        def index
          ranking_configuration = ::Books::Authors::RankingConfiguration.default_primary
          # The shared query preloads descriptions for the site's ranked page;
          # the compact resource renders none, so drop that preload and declare
          # only what this payload reads. The site is untouched.
          relation = ranking_configuration && ::Books::RankedAuthorsQuery
            .call(ranking_configuration: ranking_configuration)
            .except(:includes)
            .includes(item: {primary_image: {file_attachment: :blob}})

          render_ranked_page(relation, path: "/api/v1/authors") do |ranked_item|
            AuthorResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end

        def show
          # find_by!(slug:), never friendly.find: Books::Author uses friendly_id
          # with :finders, which resolves slugs before primary keys.
          author = ::Books::Author
            .includes(:descriptions, {primary_image: {file_attachment: :blob}})
            .find_by!(slug: params[:slug])

          render json: {data: AuthorResource.new(author, with_traits: :full).to_h}
        end
      end
    end
  end
end
