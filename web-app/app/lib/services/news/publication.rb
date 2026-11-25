module Services
  module News
    # Publish and unpublish are one field, published_at, so they go through
    # SavePost like every other write and get the lock, the purge and the
    # changed-fields report for free. Results are SavePost's.
    #
    # publish: no `at` publishes now; a future `at` schedules (or reschedules a
    # scheduled post). Codes: :past, :already_published, :invalid.
    # unpublish: back to a draft, from live or scheduled. Codes: :already_draft,
    # :invalid. Clearing the date loses it: nothing here can set an old date
    # back, so unpublish reports it as data[:was_published_at] for the audit log.
    #
    # A refusal that says the state is already what was asked for (:already_published,
    # :already_draft) purges the post's pages anyway. The first call may have
    # committed its status change and then failed to enqueue its purge; the retry
    # is refused with a 409, and without this purge nothing could ever repair the
    # stale pages. :past and :invalid change nothing, so they purge nothing.
    # The pages are counted with the post as published: a retried unpublish
    # meets the post already removed, and the index or topic page its removal
    # pushed past the end is still cached with the post on it.
    class Publication
      REPURGED = %i[already_published already_draft].freeze

      def self.publish(news_post:, at: nil)
        # Judged under the lock, in this order: a live post is a conflict whatever
        # time was sent, so a retried scheduling call gets the date it went live
        # and never a past-time error.
        guard = lambda do |locked|
          if locked.published?
            [:already_published, "The post is already published; it went live #{locked.published_at.utc.iso8601(6)}"]
          elsif at && at <= Time.current
            [:past, "The publication time is in the past; omit published_at to publish now"]
          end
        end
        result = SavePost.call(news_post: news_post, attrs: {published_at: at || Time.current}, guard: guard)
        purge_again(result)
      end

      def self.unpublish(news_post:)
        was = nil
        guard = lambda do |locked|
          was = locked.published_at
          [:already_draft, "The post is already a draft"] if was.nil?
        end
        result = SavePost.call(news_post: news_post, attrs: {published_at: nil}, guard: guard)
        result.data[:was_published_at] = was if result.success?
        purge_again(result)
      end

      # After SavePost has returned, so outside its transaction.
      def self.purge_again(result)
        if !result.success? && REPURGED.include?(result.data[:code])
          post = result.data[:news_post]
          ::News::PurgeCachedPagesJob.perform_async(post.domain, CachedUrls.call(post, as_published: true))
        end
        result
      end
      private_class_method :purge_again
    end
  end
end
