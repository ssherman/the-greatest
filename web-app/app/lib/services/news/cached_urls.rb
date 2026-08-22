module Services
  module News
    # Every edge-cached public URL that one news post's create, update or delete
    # invalidates. Returns plain strings so the caller can hand them straight to
    # News::PurgeCachedPagesJob -- Sidekiq arguments must be JSON-native.
    #
    # Called from the write path while the record still exists, NOT from inside
    # the job: a destroyed post cannot be looked up, and its news_post_topics
    # rows are gone with it (dependent: :destroy). Create and update go through
    # the same call for uniformity rather than having two shapes to test.
    #
    # What is deliberately NOT here:
    #   * query-string variants (/news?utm_source=x is its own cache entry and
    #     cannot be enumerated)
    #   * the legacy /blog_posts/* routes -- 301 redirects, not content.
    class CachedUrls
      def self.call(news_post)
        new(news_post).call
      end

      def initialize(news_post)
        @news_post = news_post
      end

      def call
        return [] if news_post.slug.blank?

        hosts.flat_map { |host| urls_for(host) }.uniq
      end

      private

      attr_reader :news_post

      # config.domains values come from ENV and each may hold a comma-separated
      # list; DomainConstraint and ApplicationController#detect_current_domain
      # both split on "," and treat every entry as a live serving host.
      # Cloudflare keys its cache by host, so all of them are purged -- unlike
      # MailBranding and MembershipController, which take .first because they
      # must name exactly ONE canonical host.
      #
      # Split without stripping, so this set is exactly the set the router
      # serves: a value the router would never match is not worth purging.
      # Blanks are dropped because "a,,b" would otherwise build "https:///news".
      def hosts
        Rails.application.config.domains[news_post.domain.to_sym]
          .to_s.split(",").reject(&:blank?)
      end

      def urls_for(host)
        [post_url(host)] + index_urls(host) + topic_urls(host)
      end

      def post_url(host)
        routes.news_post_url(slug: news_post.slug, **host_options(host))
      end

      # Every page, not just page 1: the index sorts published_at DESC, so any
      # insert or delete shifts the contents of every page after the first.
      def index_urls(host)
        pages(published_count).map do |page|
          if page == 1
            routes.news_url(**host_options(host))
          else
            routes.news_page_url(page: page, **host_options(host))
          end
        end
      end

      # ALL of the domain's topics, not only this post's. An update can change
      # topic membership, and by the time the controller enqueues, the OLD topic
      # set is unrecoverable -- purging every topic index removes the
      # distinction rather than making the caller capture before-state.
      def topic_urls(host)
        topic_counts.flat_map do |topic, count|
          pages(count).map do |page|
            if page == 1
              routes.news_topic_url(topic_slug: topic.slug, **host_options(host))
            else
              routes.news_topic_page_url(topic_slug: topic.slug, page: page, **host_options(host))
            end
          end
        end
      end

      # A domain with zero published posts still serves /news, so never fewer
      # than one page.
      def pages(count)
        1..[1, (count / NewsPost::PER_PAGE.to_f).ceil].max
      end

      def published_count
        @published_count ||= domain_scope.count
      end

      # One grouped query rather than a count per topic.
      def topic_counts
        @topic_counts ||= begin
          topics = NewsTopic.where(domain: news_post.domain).to_a
          counts = domain_scope
            .joins(:news_post_topics)
            .where(news_post_topics: {news_topic_id: topics.map(&:id)})
            .group("news_post_topics.news_topic_id")
            .count
          topics.index_with { |topic| counts.fetch(topic.id, 0) }
        end
      end

      def domain_scope
        NewsPost.where(domain: news_post.domain).published
      end

      def host_options(host)
        {host: host, protocol: "https"}
      end

      def routes
        Rails.application.routes.url_helpers
      end
    end
  end
end
