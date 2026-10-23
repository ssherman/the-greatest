# frozen_string_literal: true

namespace :books do
  namespace :alternate_titles do
    desc "Copy every book's alternate_titles array into books_alternate_titles (idempotent)"
    task backfill: :environment do
      puts "alternate titles: #{Services::AlternateTitles::Backfill.all} rows created"
    end
  end
end
