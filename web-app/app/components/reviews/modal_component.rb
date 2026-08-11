# frozen_string_literal: true

module Reviews
  # Singleton rating/review dialog, rendered once per page in the layout.
  #
  # Ships EMPTY. It lives in edge-cached HTML, so it can carry neither the
  # viewer's review nor a usable CSRF token -- the Stimulus controller sets the
  # form action, the method override, the field values and the authenticity
  # token before showing it.
  #
  # Deliberately not `form_with(model:)`: there is no record at render time, and
  # a Rails-generated hidden token here would be the cached page's stale one.
  class ModalComponent < ViewComponent::Base
    MAX_RATING = 5

    private

    def ratings
      1..MAX_RATING
    end
  end
end
