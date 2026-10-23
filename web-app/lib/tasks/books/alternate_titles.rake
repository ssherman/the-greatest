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

    desc "Undo verification findings that agreed only through a removed alternate title. Dry run unless the arg is apply: undo_findings[apply]"
    task :undo_findings, [:mode] => :environment do |_task, args|
      apply = args[:mode] == "apply"
      result = Services::Books::AlternateTitles::UndoFindings.call(apply: apply)
      data = result.data
      puts "alternate titles undo (#{apply ? "applied" : "dry run"}): #{data[:books]} books, #{data[:findings_checked]} findings checked"
      data[:undone].each { |action, count| puts "  #{action}: #{count}" }
      puts "  left alone (held with another source): #{data[:left_alone]}"
      puts "wrong work (#{data[:wrong_work].size}):"
      data[:wrong_work].each { |entry| puts "  book #{entry[:book_id]} #{entry[:title].inspect}: #{entry[:work_key]} #{entry[:work_title].inspect}" }
      puts "samples:"
      data[:samples].each { |sample| puts "  #{sample}" }
    end

    desc "Reverse one undone verification finding: redo_finding[finding_id]"
    task :redo_finding, [:finding_id] => :environment do |_task, args|
      finding = Books::VerificationFinding.find(args[:finding_id])
      result = Services::Books::AlternateTitles::UndoFindings.redo(finding: finding)
      abort "alternate titles: #{result.errors.join("; ")}" unless result.success?
      puts "alternate titles: redid finding #{finding.id}"
    end

    desc "List a book's undone verification findings, to pass to redo_finding: undone_findings[book_id]"
    task :undone_findings, [:book_id] => :environment do |_task, args|
      findings = Books::VerificationFinding.where(book_id: args[:book_id]).where.not(undone_at: nil).order(:id)
      puts "alternate titles: #{findings.size} undone findings for book #{args[:book_id]}"
      findings.each do |f|
        puts "  #{f.id} #{f.kind} #{f.identifier_type} #{f.value} source=#{f.source} undo_action=#{f.undo_action} undone_at=#{f.undone_at.iso8601} via #{f.evidence&.dig("title").inspect}"
      end
    end

    desc "Restore a removed alternate title (kept, AI verdict preserved so it is never re-sent): restore[row_id]"
    task :restore, [:row_id] => :environment do |_task, args|
      row = AlternateTitle.find(args[:row_id])
      Services::AlternateTitles::Writer.decide(row: row, status: :kept)
      puts "alternate titles: restored #{row.title.inspect}"
    end
  end
end
