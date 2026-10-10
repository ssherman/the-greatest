# frozen_string_literal: true

namespace :books do
  desc "Recompute every author's name_keys (the finders' initials-folded name keys). " \
    "Only needed if Services::Text::PersonNameKey's rule changes; saves keep the column current."
  task refresh_author_name_keys: :environment do
    data = Services::Books::RefreshAuthorNameKeys.call.data
    puts "authors: #{data[:scanned]} scanned, #{data[:updated]} updated"
  end
end
