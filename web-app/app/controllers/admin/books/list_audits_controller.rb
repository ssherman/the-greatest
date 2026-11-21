class Admin::Books::ListAuditsController < Admin::Books::BaseController
  before_action :require_domain_write!, only: [:release]

  RECENT = 50

  def index
    @counts = ::Services::Lists::Audits::Counts.call
    @agent_prompt = ::Services::AgentPrompts.for_list_audit
    @audits = books_audits.includes(:list, :user).order(started_at: :desc).limit(RECENT)
  end

  def release
    audit = books_audits.find(params[:id])
    result = ::Services::Lists::Audits::Release.call(audit: audit, user: current_user, admin: true)

    if result.success?
      redirect_to admin_books_list_audits_path, notice: "Audit released."
    else
      redirect_to admin_books_list_audits_path, alert: result.errors.to_sentence
    end
  end

  private

  def books_audits
    ::ListAudit.joins(:list).where(lists: {type: "Books::List"})
  end
end
