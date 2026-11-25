module Services
  module News
    # API update. expected_updated_at is optimistic concurrency: the caller read
    # the post, and wants the write refused if anyone changed it since. The
    # comparison runs in SavePost's guard, under the row lock, so two writers
    # holding the same stamp cannot both pass.
    #
    # Codes: :stale, :invalid.
    class EditPost
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(news_post:, attrs:, expected_updated_at: nil)
        guard = ->(locked) { stale_refusal(locked, expected_updated_at) }
        attrs = attrs.with_indifferent_access.slice(*::NewsPost::API_WRITABLE)
        saved = SavePost.call(news_post: news_post, attrs: attrs, guard: guard)
        Result.new(success?: saved.success?, data: saved.data, errors: saved.errors)
      end

      # Microsecond precision is what Postgres stores and what a caller can
      # round-trip through iso8601(6); anything finer is noise.
      def self.stale_refusal(locked, expected)
        return if expected.nil? || locked.updated_at.floor(6) == expected.floor(6)

        [:stale, "The post changed since it was read; read it again before editing"]
      end
      private_class_method :stale_refusal
    end
  end
end
