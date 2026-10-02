# frozen_string_literal: true

# Alba 4 returns string keys from #to_h by default. Every API resource and its
# tests key their hashes with symbols (rank, authors, cover_url, ...), so make
# symbol keys the app-wide default rather than converting per resource.
Alba.symbolize_keys!
