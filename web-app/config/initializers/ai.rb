# frozen_string_literal: true

# Model roles for AI tasks. Rails config, not an admin UI: a model swap is a
# reviewed deploy, and there is exactly one place to read to know which model
# every task runs on. Spec:
# docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §1.
#
# Tasks declare a role (Services::Ai::Tasks::BaseTask#task_role); nothing in
# app/ names a model ID. gpt-5-mini, which every task used to hardcode, is
# retired by OpenAI on 2026-12-11.
Rails.application.configure do
  config.x.ai.roles = {
    fast: {provider: :openai, model: "gpt-6-luna", tools: []},
    standard: {provider: :openai, model: "gpt-6-sol", tools: []},
    premium: {provider: :openai, model: "gpt-6-astra", tools: []},
    research: {provider: :openai, model: "gpt-6-astra", tools: [:web_search]}
  }

  # Enrichment skips the knowledge call and goes straight to web search for a
  # book first published in or after this year: the model's training data
  # ends before it.
  config.x.ai.knowledge_cutoff_year = 2026

  # Research-mode (web search) enrichment runs allowed per UTC day, all kinds
  # combined. Each costs roughly 15 cents. The admin action's force option
  # ignores this cap.
  config.x.ai.research_daily_cap = 50

  # The origin backfill's own research cap per UTC day, counted apart from
  # research_daily_cap so a backfill never starves imports of web searches.
  # 0 until the rehearsal has shown what a run costs; then it is raised.
  config.x.ai.categorize_backfill_research_daily_cap = 0

  # The categories judge (Services::Books::Categories::Judge) runs only when
  # this is on. Off, it writes one skipped "disabled" row and nothing else, so
  # the backfill still plans the book once it is on. Turned on in production
  # after the dev rehearsal is signed off and the definitions are written
  # (docs/launch-todo.md section 14). ENV: BOOKS_CATEGORIES_JUDGE_ENABLED.
  config.x.ai.categories_judge_enabled = %w[1 true].include?(ENV["BOOKS_CATEGORIES_JUDGE_ENABLED"].to_s.strip.downcase)
end
