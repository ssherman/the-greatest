# frozen_string_literal: true

# The pre-built CSV of one ranking configuration's full, unfiltered ranking
# (spec §6). One row per configuration -- the unique index is the invariant --
# regenerated after every successful ranking calculation and nightly for the
# global configurations, never on a TTL.
#
# The claim/stale-claim rules mirror RankingConfiguration#refresh_claimable?:
# a `generating` row whose claim is older than GENERATION_STALE_AFTER was left
# behind by a worker killed before its rescue could run, and may be re-claimed.
class CsvExport < ApplicationRecord
  GENERATION_STALE_AFTER = 15.minutes

  belongs_to :ranking_configuration
  has_one_attached :file

  enum :status, {pending: 0, generating: 1, ready: 2, failed: 3}

  validates :ranking_configuration_id, uniqueness: true

  def claimable?
    !generating? || requested_at.nil? || requested_at < GENERATION_STALE_AFTER.ago
  end

  # A `ready` row with no attachment is a row whose attach never completed;
  # serving it would 500 inside blob.download, so it counts as not ready.
  def downloadable?
    ready? && file.attached?
  end
end
