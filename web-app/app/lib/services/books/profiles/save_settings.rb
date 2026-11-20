module Services
  module Books
    module Profiles
      # Saves a reader's sharing settings. When the save hides anything that the
      # edge may have cached, the cached page is purged synchronously after the
      # row is durably committed, and the caller learns whether that worked.
      class SaveSettings
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(user:, attributes:)
          new(user: user, attributes: attributes).call
        end

        def initialize(user:, attributes:)
          @user = user
          @attributes = attributes
        end

        def call
          saved = false
          hiding = false
          committed_result = nil

          ::Books::Profile.transaction do |transaction|
            profile.assign_attributes(attributes)
            hiding = hiding_save?
            saved = profile.save
            if saved
              transaction.after_commit { committed_result = invalidate_cache(hiding) }
            end
          end

          unless saved
            return result(success: false, persisted: false, purge_confirmed: nil, errors: profile.errors.full_messages)
          end

          committed_result || result(success: true, persisted: true, purge_confirmed: nil, errors: [])
        end

        private

        attr_reader :user, :attributes

        def profile
          @profile ||= ::Books::Profile.find_or_initialize_by(user: user)
        end

        # Must run after assign_attributes and before save, while the changes
        # still describe the difference from the stored row.
        def hiding_save?
          return false unless profile.public_was

          !profile.public? ||
            profile.display_name_changed? ||
            ::Books::Profile::SECTIONS.any? { |section| profile.attribute_was("show_#{section}") && !profile.show?(section) }
        end

        def invalidate_cache(hiding)
          return result(success: true, persisted: true, purge_confirmed: nil, errors: []) unless hiding || profile.public?

          urls = CachedUrls.call(profile: profile)
          if hiding
            revoke_public_cache(urls)
          else
            enqueue(urls)
            result(success: true, persisted: true, purge_confirmed: nil, errors: [])
          end
        end

        def revoke_public_cache(urls)
          if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank? && !Rails.env.production?
            return result(success: true, persisted: true, purge_confirmed: true, errors: [])
          end

          service = ::Cloudflare::PurgeService.new
          urls.each_slice(::Books::ReadingGoals::PurgeCachedPagesJob::MAX_URLS_PER_REQUEST) do |batch|
            purge_result = service.purge_urls(:books, batch)
            next if purge_result[:success]

            return revocation_failure(urls, purge_result[:error] || "Cloudflare purge failed")
          end

          result(success: true, persisted: true, purge_confirmed: true, errors: [])
        rescue => error
          revocation_failure(urls, error.message)
        end

        def revocation_failure(urls, error)
          Rails.logger.error "[ALERT] Books profile #{profile.id} hid content but cache revocation failed: #{error}"
          enqueue(urls)
          result(success: false, persisted: true, purge_confirmed: false, errors: [error])
        end

        def enqueue(urls)
          ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
        end

        def result(success:, persisted:, purge_confirmed:, errors:)
          Result.new(
            success?: success,
            data: {profile: profile, persisted: persisted, purge_confirmed: purge_confirmed},
            errors: errors
          )
        end
      end
    end
  end
end
