# frozen_string_literal: true

# Merges every placeholder author into the canonical Unknown author
# (Services::Books::Authors::MergeUnknown). Queued by
# books:authors:merge_unknown with APPLY=1. Retry is off: a rerun is the
# rake task again, and it only finds what is left.
class Books::MergeUnknownAuthorsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform
    result = ::Services::Books::Authors::MergeUnknown.call(apply: true)
    return Rails.logger.warn("Books::MergeUnknownAuthorsJob: did not start (#{result.errors.join("; ")})") unless result.success?

    data = result.data
    Rails.logger.info(
      "Books::MergeUnknownAuthorsJob: merged #{data[:merged]} of #{data[:sources].size} placeholder author(s) " \
      "into author #{data[:target_id]}" \
      "#{"; failed: #{data[:failed].map { |f| "#{f[:id]} (#{f[:errors].join(", ")})" }.join("; ")}" if data[:failed].any?}"
    )
  end
end
