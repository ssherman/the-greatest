# frozen_string_literal: true

# Fetches one Goodreads page, when Books::Goodreads::FetchGate allows, and
# hands the id's waiting editions to SettleEditionsJob (Goodreads import spec
# §6). On the goodreads_fetch capsule: one job at a time, and the only
# caller of FetchPage.
#
# A job first takes a turn in the gate's line and reschedules itself for it;
# it never sleeps. A cached answer, nothing left waiting, a spent daily cap
# or a block means no fetch: the editions settle with what there is, which
# without a page is a book created unverified for the sweep. A challenge or
# an unrecognizable page blocks every fetch for the cooldown. No answer at
# all (Goodreads' 503 page, a timeout) is tried again through the line, up to
# fetch_attempts.
class Books::Goodreads::FetchPageJob
  include Sidekiq::Job

  sidekiq_options queue: :goodreads_fetch, retry: 3

  def perform(goodreads_book_id, due = false, attempt = 1)
    return settle(goodreads_book_id) if ::Books::GoodreadsPage.conclusive.exists?(goodreads_book_id: goodreads_book_id)
    return unless ::Books::GoodreadsEdition.awaiting_goodreads.exists?(goodreads_book_id: goodreads_book_id)

    unless due
      reservation = gate.reserve
      return settle(goodreads_book_id) unless reservation.granted?
      return self.class.perform_in(reservation.wait, goodreads_book_id, true, attempt) if reservation.wait.positive?
    end
    return settle(goodreads_book_id) if gate.blocked?

    # A turn that came due late (a deploy, a slow fetch before it) still
    # waits out the gap since the last fetch began, without a new turn.
    spacing = gate.spacing_wait
    return self.class.perform_in(spacing, goodreads_book_id, true, attempt) if spacing.positive?

    gate.started!
    outcome = ::Services::Books::GoodreadsPages::FetchPage.call(goodreads_book_id: goodreads_book_id).data[:outcome]
    gate.block! if %i[blocked unparseable].include?(outcome)
    if outcome == :unavailable && attempt < Rails.application.config.x.goodreads.fetch_attempts
      return self.class.perform_async(goodreads_book_id, false, attempt + 1)
    end

    settle(goodreads_book_id)
  end

  private

  def gate = (@gate ||= ::Books::Goodreads::FetchGate.new)

  def settle(goodreads_book_id)
    ::Books::Goodreads::SettleEditionsJob.perform_async(goodreads_book_id)
  end
end
