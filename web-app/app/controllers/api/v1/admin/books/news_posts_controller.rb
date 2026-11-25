# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/news_posts      -- the books site's posts, every status (filter: status)
        # GET /api/v1/admin/news_posts/:id  -- one post in full
        # GET /api/v1/admin/news_topics     -- the topics a post can carry
        # POST /api/v1/admin/news_posts     -- a new draft
        # PATCH /api/v1/admin/news_posts/:id -- edit a draft or a live post in place
        #
        # The actions are NewsPostActions; this class names the site and its scopes.
        # Root-anchor every ::Books:: reference in this namespace.
        class NewsPostsController < BaseController
          include ::Api::V1::Admin::NewsPostActions

          require_scopes index: "books:admin:read", show: "books:admin:read", topics: "books:admin:read",
            create: "books:admin:write", update: "books:admin:write"

          private

          def news_domain = :books

          def admin_url_for(post)
            "#{::Api::Host.base_url(news_domain)}#{edit_admin_books_news_post_path(post)}"
          end
        end
      end
    end
  end
end
