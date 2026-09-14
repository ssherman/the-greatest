# frozen_string_literal: true

module Api
  module V1
    module Books
      # The author as embedded in a book: enough to display and to follow.
      # The author index/show (increment 2) gets its own AuthorResource.
      class AuthorSummaryResource
        include Alba::Resource

        attributes :id, :slug, :name
      end
    end
  end
end
