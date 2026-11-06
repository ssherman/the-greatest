# frozen_string_literal: true

# The legacy Goodreads replay (Goodreads import spec §12). Rails config, not
# an admin UI.
Rails.application.config.x.goodreads_replay = ActiveSupport::OrderedOptions.new.merge(
  # Spec §12.9: the first full replay writes verdicts and applies nothing.
  # Switched on 2026-10-14, after the first production replay's auto
  # verdicts were hand-checked (books:goodreads_replay:sample). Only approved
  # verdicts are applied; proposed ones wait for an admin.
  auto_apply: true,
  # Name groups larger than this are not sent to the author check; the
  # largest measured group was 74 (2026-10-05).
  max_author_group: 80
)
