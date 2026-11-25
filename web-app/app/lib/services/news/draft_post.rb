module Services
  module News
    # API create: a news post always starts as a draft (publishing is its own
    # step, Publication). The slug rules run first so a title that would give a
    # UUID URL, or collide with another post, is refused up front with a code a
    # caller can act on.
    #
    # Codes: :unusable_title, :slug_taken (data[:existing] is the NewsPost that
    # holds it), :invalid (SavePost's validation failure).
    class DraftPost
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(domain:, user:, attrs:)
        new(domain: domain, user: user, attrs: attrs).call
      end

      def initialize(domain:, user:, attrs:)
        @domain = domain
        @user = user
        @attrs = attrs.with_indifferent_access.slice(*::NewsPost::API_WRITABLE)
      end

      def call
        post = ::NewsPost.new(domain: @domain, user: @user)

        # The same normalisation friendly_id applies on save, so the slug checked
        # here is the slug that would be written. A blank one (no Latin
        # characters, only punctuation) would make friendly_id fall back to a
        # UUID; a reserved word would fail validation with a vaguer message.
        slug = post.normalize_friendly_id(@attrs[:title].to_s)
        if slug.blank? || ::NewsPost.friendly_id_config.reserved_words.include?(slug)
          return refuse(:unusable_title, "The title has no usable URL slug", post)
        end

        if (existing = find_existing(post, slug))
          return slug_taken(post, slug, existing)
        end

        # Assigned explicitly: friendly_id only generates a slug when blank, so
        # it can never quietly append a UUID if a concurrent create wins the
        # race after the check above. The unique (domain, slug) index is then
        # the backstop, rescued here rather than inside SavePost so its own
        # savepoint has already rolled back.
        post.slug = slug
        begin
          saved = SavePost.call(news_post: post, attrs: @attrs)
        rescue ActiveRecord::RecordNotUnique
          existing = find_existing(post, slug)
          raise unless existing

          return slug_taken(post, slug, existing)
        end
        Result.new(success?: saved.success?, data: saved.data, errors: saved.errors)
      end

      private

      def find_existing(post, slug)
        ::NewsPost.find_by(domain: post.domain, slug: slug)
      end

      def slug_taken(post, slug, existing)
        refuse(:slug_taken, "A post with the slug #{slug.inspect} already exists on this site", post, existing: existing)
      end

      def refuse(code, message, post, extra = {})
        Result.new(success?: false, data: {news_post: post, code: code}.merge(extra), errors: [message])
      end
    end
  end
end
