# frozen_string_literal: true

# The list wizard core's step and row actions (books list wizard spec §1, §4,
# §8). A domain controller includes this and defines a private #list_class;
# the domain's adapter (Services::Lists::Wizard::Core::Adapters) does the rest.
# Every screen is a full Turbo Drive visit: no Turbo Frame, so nothing traps
# a link.
#
# One wizard job runs per list at a time. While one does (and has written
# within Services::Lists::Wizard::StateManager::STALLED_AFTER), everything
# that starts a job, deletes rows or changes a row is refused with a message.
# A job that stopped writing is treated as dead: its step may be run again.
module ListWizardCore
  extend ActiveSupport::Concern
  include WizardController

  ROW_ACTIONS = %i[link_row create_row create_row_from_text edit_row remove_row].freeze
  JOB_STEPS = %w[parse match import].freeze
  NEXT_LABELS = {"paste" => "Parse →", "parse" => "Match →", "match" => "Review →", "review" => "Import →", "import" => "Done →"}.freeze
  RESTART_CONFIRM = "Restart the wizard? Rows nobody has settled are deleted; settled rows are kept."

  included do
    before_action :refuse_auto_generated_list
    # Viewers may look; writers drive the wizard (paid AI calls); only
    # deleters may restart, which deletes the rows nobody settled.
    before_action :require_domain_write!, unless: -> { request.get? || request.head? }
    before_action :require_domain_delete!, only: [:restart]
    before_action :set_row, only: ROW_ACTIONS
    before_action :refuse_row_action_while_running, only: ROW_ACTIONS
  end

  def show_step
    super
    @wizard_adapter = wizard_adapter
    @review_filter = review_filter || ::Services::Lists::Wizard::Core::ReviewRows::FILTERS.first
    @review_page = params[:page]
    @stalled = wizard_entity.wizard_manager.step_stalled?(@step_name)
    assign_navigation
    render "admin/list_wizard_core/show_step"
  end

  def advance_step
    case params[:step]
    when "paste" then advance_from_paste
    when "parse" then advance_from_job("parse", "match")
    when "match" then advance_from_job("match", "review")
    when "review" then advance_from_review
    when "import" then advance_from_job("import", "done")
    else redirect_to action: :show_step, step: params[:step]
    end
  end

  def back_step
    index = [wizard_steps.index(params[:step]) - 1, 0].max
    wizard_entity.wizard_manager.go_to_step!(index)
    redirect_to({action: :show_step, step: wizard_steps[index]}, status: :see_other)
  end

  # Spec §8: back to Paste, deleting only the rows nobody settled. Not while
  # a job runs: it would be writing rows this deletes.
  def restart
    return refuse_while_running if any_job_running?

    ::ListItem.where(id: ::Services::Lists::Wizard::Core::RowState.unsettled(wizard_entity).map(&:id)).destroy_all
    wizard_entity.wizard_manager.reset!
    redirect_to({action: :show}, status: :see_other)
  end

  def save_content
    return if refuse_blank_paste(params[:raw_content])
    return refuse_while_running if any_job_running?

    wizard_entity.with_lock do
      wizard_entity.update!(raw_content: params[:raw_content],
        wizard_state: (wizard_entity.wizard_state || {}).merge("batch_mode" => params[:batch_mode] == "1"))
    end
    begin_parse
  end

  def reparse
    begin_parse
  end

  def rematch
    return refuse_while_running if any_job_running?

    start_job("match")
    move_to("match")
  end

  def link_row
    respond_to_row(row_actions.link(wizard_adapter.find_record(params[:record_id])))
  end

  def create_row
    respond_to_row(row_actions.create_from_external(params[:external_key].to_s))
  end

  def create_row_from_text
    respond_to_row(row_actions.create_from_text)
  end

  def edit_row
    respond_to_row(row_actions.edit_and_rematch(title: params[:title], subtitle: params[:subtitle], authors: params[:authors], year: params[:year]))
  end

  def remove_row
    respond_to_row(row_actions.remove)
  end

  protected

  def wizard_steps = wizard_entity.wizard_manager.steps

  def wizard_entity = @list

  private

  def set_wizard_entity
    @list = list_class.find(params[:list_id])
  end

  def set_row
    @row = wizard_entity.list_items.find(params[:row_id])
  end

  # Generated lists are written by their generator, not curated by hand.
  def refuse_auto_generated_list
    return unless wizard_entity.auto_generated?

    redirect_to wizard_adapter.list_path(wizard_entity), alert: "This list is generated automatically and has no wizard."
  end

  def refuse_row_action_while_running
    refuse_while_running if any_job_running?
  end

  def wizard_adapter
    @wizard_adapter ||= ::Services::Lists::Wizard::Core::Adapters.for(wizard_entity)
  end

  def row_actions
    ::Services::Lists::Wizard::Core::RowActions.new(list_item: @row, user: current_user)
  end

  def review_filter
    filter = params[:filter].to_s
    ::Services::Lists::Wizard::Core::ReviewRows::FILTERS.include?(filter) ? filter : nil
  end

  # Only a real page past the first is carried; anything else is page 1.
  def review_page
    page = params[:page].to_i
    (page > 1) ? page : nil
  end

  def job_for(step)
    {"parse" => ::Lists::Wizard::ParseJob, "match" => ::Lists::Wizard::MatchJob, "import" => ::Lists::Wizard::ImportJob}.fetch(step)
  end

  # Import gets a run id, so a second ImportJob (a double start, a retry
  # racing a new start) can tell the step is not its own (ImportRows#claim).
  def start_job(step)
    run_id = SecureRandom.uuid
    wizard_entity.wizard_manager.write_step!(step: step, status: "running", progress: 0, error: nil, metadata: {"run_id" => run_id})
    if step == "import"
      job_for(step).perform_async(wizard_entity.id, run_id)
    else
      job_for(step).perform_async(wizard_entity.id)
    end
  end

  # A step is running while its status says so and it has written lately.
  def running?(step)
    manager = wizard_entity.wizard_manager
    manager.step_status(step) == "running" && !manager.step_stalled?(step)
  end

  def running_step = JOB_STEPS.find { |step| running?(step) }

  def any_job_running? = !running_step.nil?

  def refuse_while_running(step = running_step)
    redirect_to({action: :show_step, step: step || wizard_entity.wizard_manager.current_step_name},
      alert: "A step is still running. Please wait.")
  end

  def move_to(step, completed: false)
    wizard_entity.wizard_manager.go_to_step!(wizard_steps.index(step), completed: completed)
    redirect_to({action: :show_step, step: step}, status: :see_other)
  end

  # True after redirecting back to Paste when there is nothing to parse.
  def refuse_blank_paste(content)
    return false if content.present?

    redirect_to({action: :show_step, step: "paste"}, alert: "Paste the list first.")
    true
  end

  # Every route into Parse ends here: Paste's Next, a re-parse, saved content.
  def begin_parse
    return refuse_while_running if any_job_running?

    start_job("parse")
    move_to("parse")
  end

  def advance_from_paste
    return if refuse_blank_paste(wizard_entity.raw_content)

    begin_parse
  end

  def advance_from_job(step, next_step)
    status = wizard_entity.wizard_manager.step_status(step)
    return refuse_while_running(step) if running?(step)

    # An Import that was never started gets the unlinked-rows confirmation
    # like any other way into it; a retry (failed, stalled) was confirmed.
    return advance_from_review if step == "import" && status == "idle"

    if status == "completed"
      if next_step == "match"
        return refuse_while_running if any_job_running?

        start_job("match")
      end
      move_to(next_step, completed: next_step == "done")
    else
      start_job_in_place(step)
    end
  end

  def start_job_in_place(step)
    return refuse_while_running if any_job_running?

    start_job(step)
    redirect_to({action: :show_step, step: step}, status: :see_other)
  end

  # Spec §4: moving to Import is always allowed; with flagged rows left, the
  # admin confirms once.
  def advance_from_review
    return refuse_while_running if any_job_running?

    prompt = unlinked_prompt(:refusal)
    if prompt && params[:confirm_unlinked] != "1"
      redirect_to({action: :show_step, step: "review"}, alert: prompt)
      return
    end

    start_job("import")
    move_to("import")
  end

  # The one place the flagged-rows message is worded: nil when no row is
  # flagged, otherwise the confirmation question or the refusal.
  def unlinked_prompt(kind)
    flagged = ::Services::Lists::Wizard::Core::Summary.new(wizard_entity).flagged_count
    return if flagged.zero?

    rows = "#{flagged} flagged #{"row".pluralize(flagged)}"
    (kind == :confirmation) ? "Finish with #{rows} unlinked?" : "#{rows} would stay unlinked. Finish from Review with Next and confirm."
  end

  def assign_navigation
    manager = wizard_entity.wizard_manager
    @next_label = NEXT_LABELS.fetch(@step_name, "Next →")
    @next_enabled = case @step_name
    when "paste" then wizard_entity.raw_content.present?
    when "parse", "match", "import" then manager.step_status(@step_name) == "completed"
    else true
    end
    @restart_confirm = RESTART_CONFIRM
    @next_confirm = (@step_name == "review") ? unlinked_prompt(:confirmation) : nil
    @next_params = @next_confirm ? {confirm_unlinked: "1"} : {}
  end

  # A failed action is a redirect with a message, never a re-render of the
  # mutated row. The filter and page the admin was on come back with them.
  def respond_to_row(result)
    if result.success?
      flash[:notice] = result.data[:message]
    else
      flash[:alert] = result.errors.join(" ")
    end
    redirect_to({action: :show_step, step: "review", filter: review_filter, page: review_page}.compact, status: :see_other)
  end

  def list_class
    raise NotImplementedError, "#{self.class.name} must implement #list_class"
  end
end
