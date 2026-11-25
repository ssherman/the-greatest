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
        include ::Api::JsonBody

        TITLE_LIMIT = 200
        SUMMARY_LIMIT = 500
        BODY_LIMIT = 100_000
        LIMITS = {"title" => TITLE_LIMIT, "summary" => SUMMARY_LIMIT, "body" => BODY_LIMIT}.freeze

        CREATE_FIELDS = %w[title body summary topic_ids].freeze
        UPDATE_FIELDS = (CREATE_FIELDS + %w[expected_updated_at]).freeze
        PUBLISH_FIELDS = %w[published_at].freeze

        # An ISO 8601 instant with a zone and nothing looser: Time.iso8601 turns
        # a February 30 into March 2 and DateTime.iso8601 reads +99:00 as UTC.
        TIME_FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-](0\d|1[0-4]):[0-5]\d)\z/
        # A bigint id; anything larger cannot name a topic.
        MAX_ID = 2**63 - 1

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
          render_full(post) if post
        end

        def topics
          topics = ::NewsTopic.where(domain: news_domain).sorted_by_name.to_a
          counts = ::NewsPostTopic.where(news_topic_id: topics.map(&:id)).group(:news_topic_id).count
          render json: {data: topics.map { |topic| ::Api::V1::Admin::NewsTopicResource.new(topic).to_counted_h(counts.fetch(topic.id, 0)) }}
        end

        def create
          return render_forbidden unless ::NewsPostPolicy.new(current_principal.user, ::NewsPost.new(domain: news_domain)).create?

          body = json_body
          return bad_body("The body must be a JSON object with title and body.") if body.nil?

          unknown = body.keys - CREATE_FIELDS
          return unknown_fields(unknown, CREATE_FIELDS) if unknown.any?
          return bad_body("title is required") unless body.key?("title")
          return bad_body("body is required") unless body.key?("body")

          attrs = write_attrs(body)
          return if performed?

          result = ::Services::News::DraftPost.call(domain: news_domain, user: current_principal.user, attrs: attrs)
          return refuse(result) unless result.success?

          post = result.data[:news_post]
          log_news("create", post)
          render_post(post, status: :created)
        end

        def update
          post = find_post or return
          return render_forbidden unless ::NewsPostPolicy.new(current_principal.user, post).update?

          body = json_body
          return bad_body("The body must be a JSON object with the fields to change.") if body.blank?

          unknown = body.keys - UPDATE_FIELDS
          return unknown_fields(unknown, UPDATE_FIELDS) if unknown.any?
          return bad_body("Send at least one of #{CREATE_FIELDS.join(", ")}.") if (body.keys & CREATE_FIELDS).empty?
          if body.key?("body") && !body.key?("expected_updated_at")
            return bad_body("Changing body needs expected_updated_at, the updated_at from your last read of the post.")
          end

          expected = time_param!("expected_updated_at", body["expected_updated_at"]) if body.key?("expected_updated_at")
          attrs = write_attrs(body)
          return if performed?

          result = ::Services::News::EditPost.call(news_post: post, attrs: attrs, expected_updated_at: expected)
          return refuse(result) unless result.success?

          changed = result.data[:changed].map { |key| (key == "news_topic_ids") ? "topic_ids" : key }
          log_news("update", post, changed: changed)
          render_post(post, changed: changed)
        end

        def publish
          post = find_post or return
          return render_forbidden unless ::NewsPostPolicy.new(current_principal.user, post).update?

          # No body at all means "now"; anything else must be a JSON object.
          body = request.raw_post.blank? ? {} : json_body
          return bad_body("The body must be a JSON object, or empty to publish now.") if body.nil?

          unknown = body.keys - PUBLISH_FIELDS
          return unknown_fields(unknown, PUBLISH_FIELDS) if unknown.any?

          # A key that is present goes through time_param!, null included: an
          # unset option sent as null must not quietly publish now.
          at = time_param!("published_at", body["published_at"]) if body.key?("published_at")

          result = ::Services::News::Publication.publish(news_post: post, at: at)
          return refuse(result) unless result.success?

          log_news("publish", post, changed: result.data[:changed])
          render_post(post)
        end

        def unpublish
          post = find_post or return
          return render_forbidden unless ::NewsPostPolicy.new(current_principal.user, post).update?

          result = ::Services::News::Publication.unpublish(news_post: post)
          return refuse(result) unless result.success?

          log_news("unpublish", post, changed: result.data[:changed])
          render_post(post)
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

        # After a write: the post as it now stands, re-read so the write is
        # reflected, with any extra top-level keys beside `data`.
        def render_post(post, status: :ok, **extra)
          render_full(post.reload, status: status, **extra)
        end

        def render_forbidden(detail = "Your account may not change news posts.")
          render_problem(::Api::Problem.new(:forbidden, detail: detail))
        end

        # The service-ready attributes from the body's writable keys, or nil after
        # rendering a 422 (too long, or an unknown topic). A wrong JSON type or null byte raises a 400 first.
        # Title is stripped, a blank summary is none, the body is stored as sent.
        def write_attrs(body)
          attrs = {}
          attrs["title"] = text_field(body, "title").strip if body.key?("title")
          attrs["body"] = text_field(body, "body") if body.key?("body")
          attrs["summary"] = text_field(body, "summary", nullable: true)&.strip.presence if body.key?("summary")
          attrs["news_topic_ids"] = topic_ids_field(body["topic_ids"]) if body.key?("topic_ids")

          return if over_limit?(attrs)
          return if unknown_topics?(attrs["news_topic_ids"])

          attrs
        end

        # True after rendering a 422 for the first value past its limit.
        def over_limit?(attrs)
          key, limit = LIMITS.find { |name, max| attrs[name].is_a?(String) && attrs[name].length > max }
          return false unless key

          render_problem(::Api::Problem.new(:unprocessable, detail: "#{key} must be at most #{limit} characters."))
          true
        end

        # True after rendering a 422 naming the ids that are not topics of this site.
        def unknown_topics?(ids)
          return false if ids.nil?

          known = ::NewsTopic.where(domain: news_domain, id: ids.select { |id| id.between?(1, MAX_ID) }).ids
          unknown = ids - known
          return false if unknown.empty?

          render_problem(::Api::Problem.new(:unprocessable, detail: "Unknown topic_ids for this site: #{unknown.join(", ")}. List them with list_news_topics."))
          true
        end

        def text_field(body, key, nullable: false)
          value = body[key]
          return nil if value.nil? && nullable
          raise ::Api::Page::InvalidParameter, "#{key} must be a string" unless value.is_a?(String)
          raise ::Api::Page::InvalidParameter, "#{key} must not contain a null byte" if value.include?("\u0000")

          value
        end

        # Distinct JSON integers; the unique index on the join table would 500 a repeat.
        def topic_ids_field(value)
          unless value.is_a?(Array) && value.all?(Integer)
            raise ::Api::Page::InvalidParameter, "topic_ids must be an array of integer ids"
          end

          value.uniq
        end

        # A Time from a strict ISO 8601 string, or ::Api::Page::InvalidParameter (a 400).
        def time_param!(key, value)
          unless value.is_a?(String) && value.match?(TIME_FORMAT)
            raise ::Api::Page::InvalidParameter, "#{key} must be an ISO 8601 time with a zone, such as 2026-12-01T09:00:00Z"
          end

          DateTime.iso8601(value).to_time
        rescue Date::Error
          raise ::Api::Page::InvalidParameter, "#{key} is not a real date and time"
        end

        # Service refusals as problems. A state conflict is a 409; the rest are
        # a well-formed request the post cannot take.
        def refuse(result)
          code = result.data[:code]
          return render_problem(::Api::Problem.new(:conflict, detail: taken_detail(result.data[:existing]))) if code == :slug_taken

          problem = %i[stale already_published already_draft].include?(code) ? :conflict : :unprocessable
          render_problem(::Api::Problem.new(problem, detail: result.errors.join(", ")))
        end

        def taken_detail(existing)
          "That title gives the URL of post #{existing.id} (#{existing.title.inspect}, #{existing.status}). " \
            "Choose a distinct title, such as one with the month or a qualifier."
        end

        def log_news(action, post, changed: [])
          Rails.logger.info("event=api_admin_news_post action=#{action} changed=#{changed.join(",")} " \
            "token_id=#{current_principal.token.id} token_kind=#{current_principal.token_kind} " \
            "user_id=#{current_principal.user.id} news_post_id=#{post.id}")
        end

        # A read has just loaded the post, so it is not fetched again.
        def render_full(post, status: :ok, **extra)
          render status: status, json: {data: resource(post).to_full_h, **extra}
        end
      end
    end
  end
end
