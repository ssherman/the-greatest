# frozen_string_literal: true

# Everything the owner's books list page needs for "add a book that isn't on
# the site" apart from the dropdown footer: the strip (a lazily loaded Turbo
# Frame inside the element that polls it) and the dialog. The caller renders it
# for the owner of a Books::UserList only. It lives here, not in the shared
# list view, because the controllers it names are registered for books only.
class Books::BookSubmissions::MountComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list
end
