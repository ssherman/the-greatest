# frozen_string_literal: true

# The owner's strip above a list's items: one line per submission, in its own
# Turbo Frame. Every string here came from the reader or from a lookup of
# their input, so it is printed escaped and never put in an href. Task 9
# finishes the markup and the polling. The state attributes sit on a child of
# the frame because a frame reload copies only the frame's children.
class Books::BookSubmissions::StripComponent < ViewComponent::Base
  def initialize(list:, submissions:, reload_list: false)
    @list = list
    @submissions = submissions
    @reload_list = reload_list
  end

  private

  attr_reader :list, :submissions

  def frame_data
    data = {poll_url: books_my_list_book_submissions_path(list)}
    data[:in_progress] = "true" if submissions.any?(&:in_progress?)
    data[:reload_list] = "true" if @reload_list
    data
  end

  def open?(submission) = ::Books::BookSubmission::OPEN_STATUSES.include?(submission.status)

  def message(submission)
    label = submission.label
    return "We couldn't verify #{label}, so it was removed." if submission.review_rejected?

    case submission.status
    when "queued", "looking_up" then "Adding: #{label}"
    when "needs_details" then "We couldn't find a book from that link. Try another way"
    when "added" then submission.created_book? ? "Added #{label}" : "Already on the site: added #{label}"
    when "failed" then "Could not add #{label}"
    else label.to_s
    end
  end
end
