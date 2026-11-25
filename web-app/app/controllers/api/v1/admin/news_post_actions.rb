# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The news actions, site-agnostic. The including controller names the site
      # (news_domain) and the edit page's URL (admin_url_for) and declares its
      # scopes; everything else is here, so a second site's controller is a few
      # lines. Root-anchor every constant: Api::V1::Admin has nested modules of its own.
      module NewsPostActions
        extend ActiveSupport::Concern

        include ::Api::V1::Admin::StrictIds

        def index
          status = enum_param!(:status, ::NewsPost::STATUSES)
          relation = posts.includes(:news_topics, :share_image_attachment, :body_images_attachments)
            .order(Arel.sql("news_posts.published_at DESC NULLS FIRST"), id: :desc)
          relation = relation.with_status(status) if status

          render_page(relation, path: "/api/v1/admin/news_posts", query: {status: status}.compact) do |rows|
            rows.map { |post| resource(post).to_h }
          end
        end

        def show
          post = find_post
          render_post(post) if post
        end

        def topics
          topics = ::NewsTopic.where(domain: news_domain).sorted_by_name.to_a
          counts = ::NewsPostTopic.where(news_topic_id: topics.map(&:id)).group(:news_topic_id).count
          render json: {data: topics.map { |topic| {id: topic.id, name: topic.name, slug: topic.slug, posts_count: counts.fetch(topic.id, 0)} }}
        end

        private

        def posts = ::NewsPost.where(domain: news_domain)

        def resource(post) = ::Api::V1::Admin::NewsPostResource.new(post, admin_url: admin_url_for(post))

        # This site's post by integer id, or nil after rendering the 404. A slug,
        # another site's post and an unknown id are all the same answer.
        def find_post
          post = posts.find_by(id: parse_id(params[:id]))
          return post if post

          render_problem(::Api::Problem.new(:not_found, detail: "No news post #{params[:id]}."))
          nil
        end

        # The post as it now stands, re-read so a write is reflected, with any
        # extra top-level keys beside `data`.
        def render_post(post, status: :ok, **extra)
          post.reload
          render status: status, json: {data: resource(post).to_full_h, **extra}
        end
      end
    end
  end
end
