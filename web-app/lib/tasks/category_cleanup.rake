namespace :categories do
  namespace :cleanup do
    desc "Propose decisions for one stage: bin/rails 'categories:cleanup:propose[RUN,STAGE]'. " \
      "Stages: rules, locations_head, locations_tail, subjects_head, subjects_tail. LIMIT=n, REDO=1, FORCE=1"
    task :propose, [:run, :stage] => :environment do |_task, args|
      run = args[:run].to_s
      stage = args[:stage].to_s
      ai_stages = {
        "locations_head" => ["location", :head], "locations_tail" => ["location", :tail],
        "subjects_head" => ["subject", :head], "subjects_tail" => ["subject", :tail]
      }
      abort "Usage: bin/rails 'categories:cleanup:propose[RUN,STAGE]' (STAGE: rules, #{ai_stages.keys.join(", ")})" if run.blank? || (stage != "rules" && !ai_stages.key?(stage))

      if stage == "rules"
        result = ::Services::CategoryCleanup::RulePass.call(run: run)
        puts "Rules: #{result.data[:decisions]} decisions #{result.data[:by_action].inspect}"
        next
      end

      ::CategoryCleanupDecision.for_run(run).where(stage: stage, status: %i[proposed failed]).delete_all if ENV["REDO"] == "1"
      type, tier = ai_stages.fetch(stage)
      progress = lambda do |stats|
        puts format("  calls=%d decided=%d failed_calls=%d missing=%d candidates=%d",
          stats[:calls], stats[:decided], stats[:failed_calls], stats[:missing], stats[:candidates])
      end
      pass = ::Services::CategoryCleanup::AiPass.new(run: run, category_type: type, tier: tier, limit: ENV["LIMIT"], progress: progress)
      calls = pass.call_count
      begin
        estimate = ::Services::CategoryCleanup::CostGuard.check!(calls: calls, force: ENV["FORCE"] == "1")
      rescue ::Services::CategoryCleanup::CostGuard::TooExpensive => e
        abort e.message
      end
      puts format("%s: %d calls, estimated $%.2f", stage, calls, estimate)
      puts pass.call.data.inspect
      if tier == :tail
        undecided = ::Services::CategoryCleanup::Report.undecided_head(run: run, category_type: type).size
        puts "Undecided head-tier #{type.pluralize}: #{undecided}#{" (re-run #{type.pluralize}_head)" if undecided.positive?}"
      end
    end

    desc "Print the review report for a run and write the full CSV to tmp/: bin/rails 'categories:cleanup:report[RUN]'"
    task :report, [:run] => :environment do |_task, args|
      abort "Usage: bin/rails 'categories:cleanup:report[RUN]'" if args[:run].blank?
      result = ::Services::CategoryCleanup::Report.call(run: args[:run])
      puts result.data[:lines]
      puts "", "CSV: #{result.data[:csv_path]}"
    end

    desc "Reject decisions by id (space-separated): bin/rails 'categories:cleanup:reject[RUN,12 15 19]'"
    task :reject, [:run, :ids] => :environment do |_task, args|
      ids = args[:ids].to_s.split.map(&:to_i).select(&:positive?)
      abort "Usage: bin/rails 'categories:cleanup:reject[RUN,ID ID ...]'" if args[:run].blank? || ids.empty?
      count = ::CategoryCleanupDecision.for_run(args[:run]).proposed.where(id: ids).update_all(status: ::CategoryCleanupDecision.statuses.fetch("rejected"), updated_at: Time.current)
      puts "Rejected #{count} decision(s)"
    end

    desc "Apply a run's proposed decisions: bin/rails 'categories:cleanup:apply[RUN]'"
    task :apply, [:run] => :environment do |_task, args|
      abort "Usage: bin/rails 'categories:cleanup:apply[RUN]'" if args[:run].blank?
      result = ::Services::CategoryCleanup::Applier.call(run: args[:run])
      puts "Applied: #{result.data.inspect}"
    end

    desc "Measure batch-size agreement on the tail (writes no decisions): bin/rails 'categories:cleanup:calibrate[RUN,location]'"
    task :calibrate, [:run, :type] => :environment do |_task, args|
      abort "Usage: bin/rails 'categories:cleanup:calibrate[RUN,location|subject]'" unless args[:run].present? && %w[location subject].include?(args[:type])
      sizes = ::Services::CategoryCleanup::Calibrator::SIZES
      calls = sizes.sum { |size| (200 / size.to_f).ceil }
      ::Services::CategoryCleanup::CostGuard.check!(calls: calls, force: ENV["FORCE"] == "1")
      result = ::Services::CategoryCleanup::Calibrator.call(run: args[:run], category_type: args[:type])
      puts "Sample: #{result.data[:sample]} tail #{args[:type]}s"
      result.data[:sizes].each do |row|
        puts format("Batch size %d: %.1f%% agreement over %d categories", row[:size], row[:agreement] * 100, row[:compared])
        row[:disagreements].each { |d| puts "  #{d[:name]}: one-at-a-time #{d[:one_at_a_time].inspect} vs batched #{d[:batched].inspect}" }
      end
    end
  end
end
