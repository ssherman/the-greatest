# frozen_string_literal: true

namespace :identifiers do
  desc "Once, after identifiers.source ships: mark every unmarked books identifier legacy (safe to re-run)"
  task mark_legacy: :environment do
    result = Services::Identifiers::MarkLegacy.call
    result.data[:legacy_by_type].each { |type, count| puts "#{type}: #{count} marked legacy" }
    puts "#{result.data[:legacy]} identifiers marked legacy, #{result.data[:open_library]} relabelled open_library"
  end
end
