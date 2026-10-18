# Genre cleanup (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §5).
# draft, map, split_check, report and retarget_worldcat run in development;
# apply runs in production on the reviewed files. PLAN=path and
# ASSIGNMENTS=path override the default files (tests and rehearsals).
namespace :categories do
  namespace :genres do
    plan_path = -> { ENV["PLAN"].presence || Services::Books::GenrePlan::PlanFile::DEFAULT_PATH }
    assignments_path = -> { ENV["ASSIGNMENTS"].presence || Services::Books::GenrePlan::Assignments::DEFAULT_PATH }

    desc "Draft the genre list into config/books/genre_plan.yml (FORCE=1 replaces a plan with decisions)"
    task draft: :environment do
      result = Services::Books::GenrePlan::Draft.call(path: plan_path.call, force: ENV["FORCE"] == "1")
      abort result.errors.join("\n") unless result.success?
      puts "Drafted #{result.data[:genres]} genres into #{plan_path.call}. Edit the list, then run categories:genres:map."
      Array(result.data[:notes]).each { |note| puts "  #{note}" }
    end

    desc "Map every current genre onto the edited lists (resumable)"
    task map: :environment do
      result = Services::Books::GenrePlan::Map.call(path: plan_path.call)
      abort result.errors.join("\n") unless result.success?
      d = result.data
      puts "Mapped #{d[:mapped]} genres in #{d[:batches]} batches (#{d[:failed_batches]} failed); #{d[:remaining]} still unmapped."
      puts "Run it again to retry the failed batches." if d[:remaining].positive?
    end

    desc "Ask, book by book, which halves of each split genre fit (resumable; FORCE=1 past the cost guard)"
    task split_check: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      assignments = Services::Books::GenrePlan::Assignments.load(assignments_path.call)
      calls = Services::Books::GenrePlan::SplitCheck.calls_needed(plan: plan, assignments: assignments)
      puts "split_check: #{calls} calls"
      begin
        result = Services::Books::GenrePlan::SplitCheck.call(plan: plan, assignments: assignments, force: ENV["FORCE"] == "1")
      rescue Services::CategoryCleanup::CostGuard::TooExpensive => e
        abort e.message
      end
      d = result.data
      puts "Checked #{d[:checked]} books in #{d[:calls]} calls (#{d[:failed_calls]} failed)."
    end

    desc "Print the plan for review"
    task report: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      assignments = Services::Books::GenrePlan::Assignments.load(assignments_path.call)
      validation = Services::Books::GenrePlan::Validator.call(plan: plan, assignments: assignments)
      puts Services::Books::GenrePlan::Report.call(plan: plan, assignments: assignments).data[:lines]
      puts "", (validation.success? ? "The plan passes every check." : "Problems:\n#{validation.errors.join("\n")}")
    end

    desc "Rewrite config/worldcat/genre_map.yml's targets from the plan"
    task retarget_worldcat: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      result = Services::Books::GenrePlan::RetargetWorldCat.call(plan: plan)
      abort result.errors.join("\n") unless result.success?
      puts "Retargeted #{result.data[:retargeted]} WorldCat terms."
      puts "Note: a split term, once retargeted, no longer points at the split genre. To edit a split's"
      puts "worldcat_terms and re-run, restore config/worldcat/genre_map.yml from git first."
    end

    desc "Apply the reviewed plan (production)"
    task apply: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      assignments = Services::Books::GenrePlan::Assignments.load(assignments_path.call)
      result = Services::Books::GenrePlan::Apply.call(plan: plan, assignments: assignments)
      abort result.errors.join("\n") unless result.success?
      d = result.data

      if d[:rerun]
        puts "This plan was already built for run #{plan.run.inspect}; only the applier and the cleaner ran again."
        puts "Edits to the plan file are ignored until it has a new `run:` value."
        puts "Failed decisions are not retried automatically; reset them to proposed to retry."
      end
      puts "Applied: #{d[:applier].inspect}"
      puts "Saved searches cleaned: #{d[:cleaned][:saved_searches].inspect}"
      puts "Recommendation settings cleaned: #{d[:cleaned][:recommendation_configs].inspect}"
      puts "Books on split genres with no answer (given every target): #{d[:unassigned_split_books]}"

      problems = CategoryCleanupDecision.for_run(plan.run).where(status: %i[failed stale]).includes(:category).order(:id)
      if problems.any?
        warn "WARNING: #{problems.size} decisions did not apply cleanly. This apply is PARTIAL."
        problems.each do |decision|
          warn "  ##{decision.id} #{decision.status} #{decision.category&.name.inspect} (category #{decision.category_id}): #{decision.error}"
        end
        abort "Fix the cause, reset the failed decisions to proposed, and run apply again."
      end
    end
  end
end
