# frozen_string_literal: true

namespace :books do
  namespace :alternate_titles do
    desc "Copy every book's alternate_titles array into the alternate_titles table (idempotent)"
    task backfill: :environment do
      puts "alternate titles: #{Services::AlternateTitles::Backfill.all} rows created"
    end

    desc "Queue the AI review of books' alternate titles. scope: ranked (default), all, or a count"
    task :review, [:scope] => :environment do |_task, args|
      scope = args[:scope].presence || "ranked"
      puts "alternate titles: #{Books::AlternateTitles::ReviewJob.enqueue(scope)} books queued (#{scope})"
    end

    desc "Report on the AI review of books' alternate titles"
    task report: :environment do
      puts Services::Books::AlternateTitles::Report.call
    end

    desc "Restore a removed alternate title (kept, AI verdict preserved so it is never re-sent): restore[row_id]"
    task :restore, [:row_id] => :environment do |_task, args|
      row = AlternateTitle.find(args[:row_id])
      Services::AlternateTitles::Writer.decide(row: row, status: :kept)
      puts "alternate titles: restored #{row.title.inspect}"
    end
  end
end
