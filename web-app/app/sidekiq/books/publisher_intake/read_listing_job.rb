# frozen_string_literal: true

# Reads one pending publisher listing on its turn at the source's gate (publisher
# intake design §3). On the publisher_fetch capsule, one job at a time. It never
# waits in a thread: a turn that is not due reschedules the job for it, with due true so the
# turn is not reserved twice. A refused turn simply ends: the listing is still
# pending and the sweep queues it again once the gate reopens.
class Books::PublisherIntake::ReadListingJob
  include Sidekiq::Job

  sidekiq_options queue: :publisher_fetch, retry: 2

  def perform(listing_id, due = false)
    listing = ::Books::PublisherListing.find_by(id: listing_id)
    return if listing.nil?

    data = ::Services::Books::PublisherIntake::ReadListing.call(listing: listing, due: due).data
    self.class.perform_in(data[:wait], listing_id, true) if data[:action] == :wait
  end
end
