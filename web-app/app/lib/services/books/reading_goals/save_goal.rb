module Services
  module Books
    module ReadingGoals
      class SaveGoal
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(goal:, attributes:)
          new(goal: goal, attributes: attributes).call
        end

        def initialize(goal:, attributes:)
          @goal = goal
          @attributes = attributes
        end

        def call
          before_public = goal.persisted? && goal.public?
          before_urls = before_public ? cached_urls : []

          goal.assign_attributes(attributes)
          privacy_revocation = before_public && !goal.public?

          unless goal.save
            return result(success: false, persisted: false, purge_confirmed: nil, errors: goal.errors.full_messages)
          end

          if privacy_revocation
            revoke_public_cache(before_urls)
          else
            after_urls = goal.public? ? cached_urls : []
            enqueue((before_urls + after_urls).uniq)
            result(success: true, persisted: true, purge_confirmed: nil, errors: [])
          end
        end

        private

        attr_reader :goal, :attributes

        def cached_urls
          count = ProgressQuery.call(goal: goal).count
          CachedUrls.call(goal: goal, count: count)
        end

        def revoke_public_cache(urls)
          if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank? && !Rails.env.production?
            return result(success: true, persisted: true, purge_confirmed: true, errors: [])
          end

          service = Cloudflare::PurgeService.new
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
          Rails.logger.error "[ALERT] Reading goal #{goal.id} is private but cache revocation failed: #{error}"
          enqueue(urls)
          result(success: false, persisted: true, purge_confirmed: false, errors: [error])
        end

        def enqueue(urls)
          ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
        end

        def result(success:, persisted:, purge_confirmed:, errors:)
          Result.new(
            success?: success,
            data: {goal: goal, persisted: persisted, purge_confirmed: purge_confirmed},
            errors: errors
          )
        end
      end
    end
  end
end
