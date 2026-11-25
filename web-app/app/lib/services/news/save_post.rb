module Services
  module News
    # The one write path for a news post, shared by the admin pages and the admin
    # API. Lock, guard, assign, validate, attach, save, then purge.
    #
    #   guard: callable given the locked post BEFORE assignment; returns nil, or
    #          [code, message] to refuse.
    #
    # Success: data {news_post:, changed: [String]}. Failure: data {news_post:,
    # code:}, code being :invalid or the guard's. A refusal rolls everything
    # back, including the topic join rows (assigning news_topic_ids on a persisted
    # record writes the join table immediately).
    class SavePost
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      TRACKED = %w[title body summary published_at news_topic_ids].freeze

      def self.call(news_post:, attrs:, body_images: [], guard: nil)
        new(news_post: news_post, attrs: attrs, body_images: body_images, guard: guard).call
      end

      def initialize(news_post:, attrs:, body_images:, guard:)
        @news_post = news_post
        @attrs = attrs
        @body_images = body_images
        @guard = guard
      end

      def call
        @urls_before = []
        @result = nil

        if @news_post.persisted?
          @news_post.with_lock { write }
        else
          NewsPost.transaction { write }
        end
        return @result if @result

        # Unconditional, with no published? gate: a wrong gate means a published
        # post that never purges, which is the 24-hour-stale bug this exists to
        # remove, while a needless purge costs a few origin re-renders. It also
        # covers the worst case for free -- setting published_at back to nil comes
        # through here, so a retracted post's page is purged like any other edit.
        #
        # Explicit, not a model callback: an after_commit making an external HTTP
        # call is invisible to its callers and would fire from the legacy-blog
        # data migration and from every test that creates a post. Both arguments
        # are JSON-native so they survive Sidekiq's serialisation unchanged. It
        # runs after the block so the purge never precedes the commit.
        urls = (Services::News::CachedUrls.call(@news_post) + @urls_before).uniq
        ::News::PurgeCachedPagesJob.perform_async(@news_post.domain, urls)

        Result.new(success?: true, data: {news_post: @news_post, changed: @changed}, errors: [])
      end

      private

      def write
        if (refusal = @guard&.call(@news_post))
          return fail!(refusal.first, [refusal.last])
        end

        # Captured BEFORE assign_attributes, and unioned with the post-save set
        # in #call. An update is the one write where neither state contains the
        # other: unpublishing the 11th post, or dropping the topic that gave a
        # topic index its 11th, REMOVES /news/page/2 (or the topic's page 2), so a
        # set derived only from the saved state sees 10 rows, derives one page, and
        # leaves the disappearing page cached with the retracted post on it for the
        # full 6-hour TTL. Create can only grow the set, so one snapshot on the
        # correct side of the write covers both. Must precede assign_attributes:
        # assigning news_topic_ids on a persisted record writes the join table.
        @urls_before = @news_post.persisted? ? Services::News::CachedUrls.call(@news_post) : []
        before = snapshot

        @news_post.assign_attributes(@attrs)

        # Attach only once known valid: has_many_attached#attach saves eagerly for
        # a persisted, unchanged record (`record.persisted? && !record.changed?`).
        # Gating on valid? removes any dependence on changed? -- nothing is
        # attached until the assigned record has been found valid, whichever
        # validation is the one that fails. Attached rather than mass-assigned:
        # assigning to a has_many_attached replaces the whole collection, so
        # adding one screenshot would silently drop every image already on it.
        return fail!(:invalid, @news_post.errors.full_messages) unless @news_post.valid?

        images = Array(@body_images).compact_blank
        @news_post.body_images.attach(images) if images.any?

        return fail!(:invalid, @news_post.errors.full_messages) unless @news_post.save

        after = snapshot
        @changed = TRACKED.reject { |key| before[key] == after[key] }
      end

      # Compared by value rather than read from saved_changes: attrs may be
      # permitted params (strings), and attach can itself save a persisted record.
      def snapshot
        TRACKED.index_with do |key|
          (key == "news_topic_ids") ? @news_post.news_topic_ids.sort : @news_post.public_send(key)
        end
      end

      def fail!(code, errors)
        @result = Result.new(success?: false, data: {news_post: @news_post, code: code}, errors: errors)
        raise ActiveRecord::Rollback
      end
    end
  end
end
