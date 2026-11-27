# Records legacy's book on replay rows that lack it (Services::Books::GoodreadsReimport::LinkLegacyBooks), for a
# batch of readers; .enqueue queues every reader with unlinked rows. Run it after books:goodreads_replay:load brings
# new imports, before the survey and decide read the column. Does nothing while the re-import gate is off. Re-running
# is safe: only empty columns are written.
class Books::GoodreadsReimport::LinkLegacyBooksJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 50

  # Returns how many readers were queued.
  def self.enqueue
    user_ids = ::Services::Books::GoodreadsReimport::LinkLegacyBooks.user_ids_to_link
    user_ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    user_ids.size
  end

  def perform(user_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    data = ::Services::Books::GoodreadsReimport::LinkLegacyBooks.call(user_ids: user_ids).data
    Rails.logger.info("link_legacy_books batch: #{user_ids.size} users — linked #{data[:linked]}, unlinked #{data[:unlinked]}")
  end
end
