module Services
  module Lists
    module Audits
      class Start
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MAX_TRIES = 5

        def self.call(user:, list: nil)
          new(user: user, list: list).call
        end

        def initialize(user:, list:)
          @user = user
          @list = list
        end

        def call
          @list ? start_on_list : start_next
        end

        private

        def start_on_list
          held = ::ListAudit.in_progress.find_by(list_id: @list.id)
          if held&.user_id == @user.id && !held.expired?
            held.update!(lease_expires_at: Time.current + ::ListAudit::LEASE)
            return success(held, resumed: true)
          end

          audit = claim(@list)
          return success(audit, resumed: false) if audit

          conflict(::ListAudit.in_progress.find_by(list_id: @list.id))
        end

        def start_next
          Queue.relation.first(MAX_TRIES).each do |candidate|
            audit = claim(candidate)
            return success(audit, resumed: false) if audit
          end
          success(nil, resumed: false)
        end

        # Releases an expired holder, then inserts. Returns nil when someone else
        # holds the list (the unique index decides, so two callers cannot both win).
        # The savepoint keeps a lost race from aborting the surrounding transaction.
        def claim(list)
          expired = ::ListAudit.expired.find_by(list_id: list.id)
          expired&.update!(status: :released, finished_at: Time.current, note: "lease expired")

          now = Time.current
          ::ListAudit.transaction(requires_new: true) do
            ::ListAudit.create!(
              list_id: list.id, user: @user, status: :in_progress, started_at: now,
              lease_expires_at: now + ::ListAudit::LEASE, before: Snapshot.call(list)
            )
          end
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        def success(audit, resumed:)
          Result.new(success?: true, data: {audit: audit, resumed: resumed, remaining: Queue.remaining}, errors: [])
        end

        def conflict(holder)
          who = holder&.user&.then { |u| u.name.presence || u.email } || "another user"
          until_at = holder&.lease_expires_at&.iso8601
          Result.new(
            success?: false, data: {conflict: true},
            errors: ["List #{@list.id} is being audited by #{who} until #{until_at}"]
          )
        end
      end
    end
  end
end
