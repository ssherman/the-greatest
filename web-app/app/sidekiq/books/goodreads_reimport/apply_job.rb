# Applies the approved re-import verdicts (Services::Books::GoodreadsReimport::Apply), 500 at a time, and queues
# itself again with the cursor until one walk through the phases has reached the end. Does nothing while the re-import gate is off. One at a time: a
# second copy (a double enqueue, a retry overlapping a run) finds the advisory lock taken and leaves at once,
# so two runs never apply the same verdicts together. The next call is queued after the lock is released.
class Books::GoodreadsReimport::ApplyJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  # Session advisory lock key. The verification run holds 7_262_024_100_801, the rebuild survey ...802.
  LOCK_KEY = 7_262_024_100_803

  # cursor: where the previous call of this chain stopped (Apply's data[:cursor]); nil starts a new chain.
  def perform(cursor = nil)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    data = locked { ::Services::Books::GoodreadsReimport::Apply.call(after: cursor).data }
    return unless data

    Rails.logger.info("Goodreads re-import apply: applied #{data[:applied]}, noop #{data[:noop]}, failed #{data[:failed]}, cursor #{data[:cursor].inspect}")
    self.class.perform_async(data[:cursor]) if data[:cursor]
  end

  private

  def locked
    ::ActiveRecord::Base.connection_pool.with_connection do |connection|
      return nil unless connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")

      begin
        yield
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{LOCK_KEY})")
      end
    end
  end
end
