# frozen_string_literal: true

module Services
  module Books
    module RepairVerdicts
      # An admin's review of a repair verdict, shared by the admin page and the admin API. Approving never applies:
      # books:goodreads_replay:apply does. decided_by stays the finder's (rule or ai); the reviewer is
      # decided_by_user_id and reviewed_at, and reviewed_via says which surface they used ("admin_ui" or "api").
      class Review
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.approve(verdict:, user:, via:)
          verdict.with_lock do
            next failure(:not_proposed, "This verdict is already #{verdict.status}.") unless verdict.proposed?

            stamp!(verdict, :approved, user, via)
            success(verdict: verdict)
          end
        end

        # An applied merge or relink cannot be taken back here, but rejecting it still matters: every replay pass
        # re-applies approved verdicts after a books re-migration, and a rejected one is never applied again. An applied
        # mark_provisional can be taken back, so it is.
        def self.reject(verdict:, user:, via:)
          verdict.with_lock do
            next failure(:already_rejected, "This verdict is already rejected.") if verdict.rejected?

            applied = verdict.applied_at.present?
            reverted = applied && verdict.mark_provisional?
            revert_provisional(verdict) if reverted
            stamp!(verdict, :rejected, user, via)
            success(verdict: verdict, applied: applied, reverted: reverted)
          end
        end

        # Approves the proposed, current verdicts among ids; every other id (already reviewed, superseded, unknown) is
        # skipped. The candidates are locked and re-selected inside one transaction, so a verdict reviewed meanwhile is
        # skipped, not overwritten.
        def self.bulk_approve(ids:, user:, via:)
          ids = Array(ids).map(&:to_i).uniq
          approved_ids = ::Books::RepairVerdict.transaction do
            candidates = ::Books::RepairVerdict.current.proposed.where(id: ids).order(:id).lock.pluck(:id)
            now = Time.current
            ::Books::RepairVerdict.where(id: candidates).update_all(
              status: ::Books::RepairVerdict.statuses[:approved], decided_by_user_id: user.id, reviewed_at: now,
              reviewed_via: ::Books::RepairVerdict.reviewed_via.fetch(via.to_s), updated_at: now
            )
            candidates
          end
          success(approved_ids: approved_ids, skipped_ids: ids - approved_ids)
        end

        def self.stamp!(verdict, status, user, via)
          verdict.update!(status: status, decided_by_user_id: user.id, reviewed_at: Time.current, reviewed_via: via)
        end

        def self.revert_provisional(verdict)
          result = ::Services::Books::GoodreadsReplay::Apply::MarkProvisional.revert(verdict: verdict)
          ::Services::RankingConfigurations::RequestRefresh.call_for_ids(result.data[:ranking_configuration_ids], delay: 5.minutes)
          verdict.update!(applied_at: nil)
        end

        def self.success(data) = Result.new(success?: true, data: data, errors: [])

        def self.failure(code, message) = Result.new(success?: false, data: {code: code}, errors: [message])

        private_class_method :stamp!, :revert_provisional, :success, :failure
      end
    end
  end
end
