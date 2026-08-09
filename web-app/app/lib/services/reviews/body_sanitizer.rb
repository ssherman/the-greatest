module Services
  module Reviews
    # Single implementation of review-body cleaning. Called from Review's
    # before_validation and directly by the increment-2 migrator, which bulk-inserts
    # and so bypasses callbacks.
    #
    # Step order is load-bearing:
    #   1. tokenize <spoiler> -- sanitizing first would strip the tag and keep its
    #      content, printing the spoiler in the clear.
    #   2. sanitize.
    #   3. restore tokens -- doing this after sanitizing is what stops a user from
    #      supplying their own class attribute, since `span` is not in ALLOWED_TAGS.
    #   4. .presence -- an <img>-only body is non-blank on input but sanitizes to "".
    #
    # The token is a per-call SecureRandom hex embedded in plain alphanumerics. A NUL
    # byte sentinel does NOT survive: Nokogiri strips NULs, which would silently drop
    # the markers and leak the spoiler.
    #
    # Does not truncate. Length is a Review validation, so an over-long paste raises a
    # user-visible error instead of losing text.
    class BodySanitizer
      ALLOWED_TAGS = %w[p br a i b em strong blockquote].freeze
      ALLOWED_ATTRIBUTES = %w[href title].freeze
      SPOILER_CLASS = "review-spoiler".freeze
      SPOILER_PATTERN = %r{<spoiler[^>]*>(.*?)</spoiler>}im

      def self.call(body)
        new(body).call
      end

      def initialize(body)
        @body = body
      end

      def call
        return nil if @body.blank?

        token = SecureRandom.hex(8)
        tokenized = tokenize_spoilers(@body.to_s, token)
        sanitized = sanitizer.sanitize(
          tokenized, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES
        ).to_s

        restore_spoilers(sanitized, token).presence
      end

      private

      def sanitizer
        @sanitizer ||= Rails::HTML5::SafeListSanitizer.new
      end

      def tokenize_spoilers(text, token)
        text.gsub(SPOILER_PATTERN) { "spo#{token}#{$1}spc#{token}" }
      end

      def restore_spoilers(text, token)
        text
          .gsub("spo#{token}", %(<span class="#{SPOILER_CLASS}">))
          .gsub("spc#{token}", "</span>")
      end
    end
  end
end
