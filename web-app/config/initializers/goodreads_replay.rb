# frozen_string_literal: true

# The legacy Goodreads replay (Goodreads import spec §12). Rails config, not
# an admin UI.
Rails.application.config.x.goodreads_replay = ActiveSupport::OrderedOptions.new.merge(
  # Spec §12.9: the first full replay writes verdicts and applies nothing.
  # Switch on only after 50 auto verdicts per kind are hand-checked
  # (books:goodreads_replay:sample).
  auto_apply: false,
  # Name groups larger than this are not sent to the author check; the
  # largest measured group was 74 (2026-10-05).
  max_author_group: 80
)
