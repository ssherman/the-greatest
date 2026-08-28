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
          write = nil
          committed_result = nil
          goal.class.transaction do |transaction|
            write = capture_and_save
            if write[:persisted]
              transaction.after_commit do
                committed_result = invalidate_cache(write)
              end
            end
          end

          unless write[:persisted]
            return result(success: false, persisted: false, purge_confirmed: nil, errors: goal.errors.full_messages)
          end

          committed_result || result(success: true, persisted: true, purge_confirmed: nil, errors: [])
        rescue ActiveRecord::RecordNotFound
          result(
            success: false,
            persisted: false,
            purge_confirmed: nil,
            errors: ["Reading goal no longer exists"]
          )
        end

        private

        attr_reader :goal, :attributes

        # Every Books completion mutation takes the owner's row first. Goal
        # writes use the same order -- owner, then goal -- so neither path can
        # observe half of the other's before/after count window or deadlock by
        # acquiring the same two coordination locks in reverse.
        def capture_and_save
          lock_current_owner
          goal.reload(lock: true) if goal.persisted?

          before_public = goal.persisted? && goal.public?
          before_urls = before_public ? cached_urls : []
          goal.assign_attributes(attributes)
          privacy_revocation = before_public && !goal.public?

          if goal.save
            after_urls = goal.public? ? cached_urls : []
            {
              persisted: true,
              privacy_revocation: privacy_revocation,
              before_urls: before_urls,
              urls: (before_urls + after_urls).uniq
            }
          else
            {persisted: false}
          end
        end

        def invalidate_cache(write)
          if write[:privacy_revocation]
            revoke_public_cache(write[:before_urls])
          else
            enqueue(write[:urls])
            result(success: true, persisted: true, purge_confirmed: nil, errors: [])
          end
        end

        def lock_current_owner
          owner_id = if goal.persisted?
            goal.class.where(id: goal.id).pick(:user_id)
          else
            goal.user_id
          end
          ::User.lock.find(owner_id)
        end

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
