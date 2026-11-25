module Services
  module News
    # Publish and unpublish are one field, published_at, so they go through
    # SavePost like every other write and get the lock, the purge and the
    # changed-fields report for free.
    #
    # publish: no `at` publishes now; a future `at` schedules (or reschedules a
    # scheduled post). Codes: :past, :already_published.
    # unpublish: back to a draft, from live or scheduled. Code: :already_draft.
    class Publication
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.publish(news_post:, at: nil)
        # Needs no lock: it judges the caller's argument, not the stored post.
        if at && at <= Time.current
          return Result.new(success?: false, data: {news_post: news_post, code: :past}, errors: ["The publication time is in the past"])
        end

        guard = ->(locked) { [:already_published, "The post is already published"] if locked.published? }
        wrap(SavePost.call(news_post: news_post, attrs: {published_at: at || Time.current}, guard: guard))
      end

      def self.unpublish(news_post:)
        guard = ->(locked) { [:already_draft, "The post is already a draft"] if locked.published_at.nil? }
        wrap(SavePost.call(news_post: news_post, attrs: {published_at: nil}, guard: guard))
      end

      def self.wrap(saved)
        Result.new(success?: saved.success?, data: saved.data, errors: saved.errors)
      end
      private_class_method :wrap
    end
  end
end
