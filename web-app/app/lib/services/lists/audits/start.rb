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
          # Conditional write: renew only if the row is still ours and unexpired at
          # write time (a concurrent Finish/Release/Start may have changed it).
          renewed = ::ListAudit.open.where(list_id: @list.id, user_id: @user.id)
            .update_all(lease_expires_at: Time.current + ::ListAudit::LEASE, updated_at: Time.current)
          if renewed > 0
            return success(::ListAudit.in_progress.find_by!(list_id: @list.id), resumed: true)
          end

          audit = claim(@list)
          return success(audit, resumed: false) if audit

          conflict(::ListAudit.in_progress.find_by(list_id: @list.id))
        end

        # A no-id start always claims a new list: two sessions on one admin account
        # must never share a list. Resume is by list_id only (start_on_list).
        def start_next
          Queue.relation.first(MAX_TRIES).each do |candidate|
            next if ::ListAudit.finished.exists?(list_id: candidate.id) # finished since the queue was read
            audit = claim(candidate)
            return success(audit, resumed: false) if audit
          end
          success(nil, resumed: false)
        end

        # Releases an expired holder, then inserts. Returns nil when someone else
        # holds the list (the unique index decides, so two callers cannot both win).
        # The savepoint keeps a lost race from aborting the surrounding transaction.
        def claim(list)
          # Conditional write: Postgres re-checks the WHERE after any row-lock wait, so
          # a Finish that commits first is never overwritten by this release.
          now = Time.current
          ::ListAudit.expired.where(list_id: list.id)
            .update_all(status: ::ListAudit.statuses[:released], finished_at: now, note: "lease expired", updated_at: now)

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
          who = holder&.user&.then { |u| u.name.presence || "user ##{u.id}" } || "another user"
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
