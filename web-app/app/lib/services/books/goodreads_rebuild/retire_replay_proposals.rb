# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Retires the replay's still-proposed relinks and identifier strips
      # (rebuild spec §6). They were decided against legacy's stripped titles,
      # the evidence the rebuild throws out, so they must never be approved.
      # Each is marked rejected and superseded: the admin queue hides it, the
      # replay can't revive it, and the rebuild records over it when it reaches
      # the same subject (RecordVerdict replace_superseded). Approved and
      # applied verdicts stay. A dry run unless apply.
      class RetireReplayProposals
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KINDS = %w[relink strip_identifier].freeze

        def self.call(apply: false)
          new(apply: apply).call
        end

        def initialize(apply:)
          @apply = apply
        end

        def call
          # unapplied: RecordVerdict can return an applied, unreviewed verdict to
          # proposed with applied_at kept; that one stays as it is.
          scope = ::Books::RepairVerdict.proposed.current.unapplied.where(kind: KINDS)
          counts = KINDS.index_with(0).merge(scope.group(:kind).count)
          if @apply
            now = Time.current
            scope.update_all(status: ::Books::RepairVerdict.statuses[:rejected], superseded_at: now, updated_at: now)
          end
          Result.new(success?: true, data: {counts: counts, applied: @apply}, errors: [])
        end
      end
    end
  end
end
