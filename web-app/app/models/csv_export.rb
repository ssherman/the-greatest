# frozen_string_literal: true

# The pre-built CSV of one ranking configuration's full, unfiltered ranking
# (spec §6). One row per configuration -- the unique index is the invariant --
# regenerated after every successful ranking calculation and nightly for the
# global configurations, never on a TTL.
#
# The claim/stale-claim rules follow RankingConfiguration#refresh_claimable?
# with one deliberate difference: a `generating` row with no requested_at is
# treated as abandoned too, not just one whose claim is older than
# GENERATION_STALE_AFTER -- a claim always stamps the timestamp, so a missing
# one means the row was never properly claimed.
class CsvExport < ApplicationRecord
  GENERATION_STALE_AFTER = 15.minutes

  belongs_to :ranking_configuration
  has_one_attached :file

  enum :status, {pending: 0, generating: 1, ready: 2, failed: 3}

  # The rows a caller may claim for generation, as SQL, kept beside claimable?
  # so the two cannot drift: not generating, or generating with no claim
  # timestamp, or generating under a claim older than the stale window.
  scope :claimable, -> {
    where("status <> :generating OR requested_at IS NULL OR requested_at < :stale",
      generating: statuses[:generating], stale: GENERATION_STALE_AFTER.ago)
  }

  def claimable?
    !generating? || requested_at.nil? || requested_at < GENERATION_STALE_AFTER.ago
  end

  # Whatever `status` says about the latest attempt, an attached file is a good
  # file: Generate only attaches on success. So a member keeps downloading the
  # last good file while a regeneration runs or after one fails (spec §8, §13).
  def downloadable?
    file.attached?
  end
end
