# frozen_string_literal: true

module Api
  module V1
    module Admin
      # A news post as an admin API client sees it. Key order here IS the order
      # in config/api/v1/admin_openapi.yaml. Site-agnostic: the controller works
      # out the admin URL, because the edit page's route is per site.
      class NewsPostResource
        def initialize(post, admin_url:)
          @post = post
          @admin_url = admin_url
        end

        # A list row: everything but the body.
        def to_h
          {
            id: @post.id,
            title: @post.title,
            slug: @post.slug,
            status: @post.status,
            published_at: time(@post.published_at),
            url: "#{::Api::Host.base_url(@post.domain.to_sym)}/news/#{@post.slug}",
            admin_url: @admin_url,
            summary: @post.summary,
            topics: @post.news_topics.sort_by(&:name).map { |topic| ::Api::V1::Admin::NewsTopicResource.new(topic).to_h },
            has_share_image: @post.share_image.attached?,
            body_images_count: @post.body_images.size,
            created_at: time(@post.created_at),
            updated_at: time(@post.updated_at)
          }
        end

        # The row plus the stored Markdown, what readers see and the excerpt.
        # updated_at has microseconds so an edit can be sent back against it.
        def to_full_h
          to_h.merge(
            body: @post.body,
            body_html: ::Services::News::BodyRenderer.call(@post.body).to_s,
            excerpt: @post.excerpt
          )
        end

        private

        def time(value) = value&.utc&.iso8601(6)
      end
    end
  end
end
