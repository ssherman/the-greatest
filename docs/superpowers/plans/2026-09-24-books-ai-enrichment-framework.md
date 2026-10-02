# Books AI Enrichment Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every AI task a config-driven model role, add a web-search tool and a shared enrichment ledger to the AI stack, and use them to fill a `Books::Book`'s missing metadata and description from one background job with a web-search fallback.

**Architecture:** Tasks declare a role (`fast`, `standard`, `premium`, `research`) that `config/initializers/ai.rb` maps to a provider and model; `OpenaiStrategy` learns to send the `web_search` tool and return citations. A polymorphic `enrichments` table records one row per run with per-field confidence. `Services::Books::EnrichBook` runs `BookFactsTask` in knowledge mode, reviews the description with a cheap task plus a deterministic check, applies facts under a fill-blanks policy in `ApplyBookFacts`, and re-runs in research mode when the model did not recognize the book, under a daily cap. Entry points are an importer provider, an admin action, and rake tasks.

**Tech Stack:** Rails 8, Minitest + Mocha + fixtures, Sidekiq 9, `openai` gem 0.90 (Responses API, `OpenAI::BaseModel` schemas), Playwright for the one admin E2E test, standardrb.

**Spec:** `docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md`

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- Use generators for the model (`bin/rails generate model Enrichment`) and the job (`bin/rails generate sidekiq:job books/enrich_book`), then replace the generated bodies with the code below. Never hand-create a model or job file.
- No file in `app/` may contain the string `gpt-5-mini` when this plan is done (spec §1). Model IDs live only in `config/initializers/ai.rb`.
- Every `OpenAI::BaseModel` schema is used as a class: `Schema.to_json_schema`, never `Schema.new.to_json_schema`.
- Every `Books::` constant inside `Services::Books`, `Actions::Admin::Books`, and `DataImporters::Books` is root-anchored (`::Books::Book`), because a bare `Books::Book` resolves to the enclosing module and raises `NameError`.
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`.
- Sidekiq runs inline in tests. Any test that would enqueue `Books::EnrichBookJob` for real must `expects(:perform_async)` or wrap in `Sidekiq::Testing.fake! { }`.
- Result pattern for services: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Lint with `bundle exec standardrb` (not `bin/rubocop`). Run `bin/rails test` before claiming a task done.
- Descriptions are written only through `assign_description(source: :ai_generated, ...)`, never the `books_books.description` column.
- Nothing overwrites a non-blank `Books::Book` value (spec §4).
- Commit after each task on the branch `books-ai-enrichment-spec` (already checked out in the main checkout; if executing in a worktree, branch from it). Never commit to `main`.

## Review Focus

1. **The model returns `confidence` outside high/medium/low** (e.g. `"certain"`). Expected: the ledger row still saves, with `confidence` nil, and facts still apply. Test pinned in Task 7.
2. **A research run after a knowledge run fills a field the knowledge run left blank, but the knowledge run already wrote an `ai_generated` description.** Expected: the research description is recorded `already_set`, not duplicated. Test pinned in Task 5.
3. **`origin_countries` returns `"USA"` and the countries table has `American`.** Expected: `no_match` recorded with the unmatched names kept; no `Books::BookCountry` created; no exception. Test pinned in Task 5.
4. **The response's message item has no `annotations` method (older SDK shape or a mock).** Expected: `citations: []`, no `NoMethodError`. Test pinned in Task 2.
5. **`force_research: "0"` arrives from the admin checkbox unchecked.** Expected: a knowledge run, not research. Test pinned in Task 10.

---

### Task 1: Model roles in config and on `BaseTask`; retire `gpt-5-mini`

**Files:**
- Create: `web-app/config/initializers/ai.rb`
- Create: `web-app/app/lib/services/ai/roles.rb`
- Create: `web-app/test/lib/services/ai/roles_test.rb`
- Modify: `web-app/app/lib/services/ai/tasks/base_task.rb`
- Modify: `web-app/app/lib/services/ai/providers/openai_strategy.rb` (`default_model`)
- Modify: the 13 task files listed in Step 6 and the 12 test files listed in Step 7
- Modify: `web-app/test/lib/services/ai/tasks/base_task_test.rb`
- Modify: `web-app/test/lib/services/ai/providers/openai_strategy_test.rb:23`

**Interfaces:**
- Produces: `Services::Ai::Roles.resolve(name) -> Services::Ai::Roles::Role` with `#name`, `#provider` (Symbol), `#model` (String), `#tools` (frozen Array of Symbols). `Services::Ai::Roles.names -> Array<Symbol>`. `Services::Ai::Roles::UnknownRole < ArgumentError`.
- Produces: `BaseTask#task_role` (private, default `:fast`), `BaseTask#role` (private reader). Model precedence: `model:` argument, then `task_model`, then role. Provider precedence: `provider:` argument, then `task_provider`, then role.
- Produces: `Rails.application.config.x.ai.roles`, `.knowledge_cutoff_year`, `.research_daily_cap`.

- [ ] **Step 1: Write the failing roles test**

`web-app/test/lib/services/ai/roles_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    class RolesTest < ActiveSupport::TestCase
      test "resolves the four roles from config" do
        assert_equal %i[fast standard premium research], Roles.names
      end

      test "a role carries provider, model and tools" do
        role = Roles.resolve(:research)

        assert_equal :research, role.name
        assert_equal :openai, role.provider
        assert_equal "gpt-6-astra", role.model
        assert_equal [:web_search], role.tools
        assert role.frozen?
      end

      test "roles without tools resolve to an empty tools array" do
        assert_equal [], Roles.resolve(:fast).tools
      end

      test "accepts a string name" do
        assert_equal Roles.resolve(:standard), Roles.resolve("standard")
      end

      test "an unknown role raises" do
        error = assert_raises(Roles::UnknownRole) { Roles.resolve(:nope) }
        assert_includes error.message, "nope"
        assert_includes error.message, "fast"
      end

      test "every configured provider is one AiChat can record" do
        Roles.names.each do |name|
          assert AiChat.providers.key?(Roles.resolve(name).provider.to_s), "#{name} names an unknown provider"
        end
      end

      test "no configured model is the retired gpt-5-mini" do
        Roles.names.each do |name|
          refute_equal "gpt-5-mini", Roles.resolve(name).model
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web-app && bin/rails test test/lib/services/ai/roles_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Ai::Roles`.

- [ ] **Step 3: Add the initializer and the resolver**

`web-app/config/initializers/ai.rb`:

```ruby
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
end
```

`web-app/app/lib/services/ai/roles.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    # Reads config.x.ai.roles. The only place that does, so a test can stub
    # one method to change which model a task runs on.
    module Roles
      Role = Struct.new(:name, :provider, :model, :tools, keyword_init: true)

      class UnknownRole < ArgumentError; end

      def self.resolve(name)
        name = name.to_sym
        config = configured[name]
        if config.nil?
          raise UnknownRole, "Unknown AI role #{name.inspect}; roles are #{names.join(", ")}"
        end

        Role.new(
          name: name,
          provider: config.fetch(:provider).to_sym,
          model: config.fetch(:model),
          tools: Array(config[:tools]).map(&:to_sym).freeze
        ).freeze
      end

      def self.names
        configured.keys
      end

      def self.configured
        Rails.application.config.x.ai.roles
      end
      private_class_method :configured
    end
  end
end
```

- [ ] **Step 4: Run the roles test**

Run: `cd web-app && bin/rails test test/lib/services/ai/roles_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 5: Teach `BaseTask` about roles**

Replace the top of `web-app/app/lib/services/ai/tasks/base_task.rb` (the `initialize` method) and the provider factory. The full file after the change:

```ruby
module Services
  module Ai
    module Tasks
      class BaseTask
        include Services::Ai::Capable

        def initialize(parent:, provider: nil, model: nil)
          @parent = parent
          validate_parent!
          @role = Services::Ai::Roles.resolve(task_role)
          @provider = provider || create_provider(task_provider || @role.provider)
          @model = model || task_model || @role.model
        end

        def call
          # Create the chat when we actually need it
          @chat = create_chat!

          # Add user message to chat history
          user_content = user_prompt_with_fallbacks
          add_user_message(user_content)

          # Get response from provider
          provider_response = @provider.send_message!(
            ai_chat: @chat,
            content: user_content,
            response_format: supports?(:json_mode) ? response_format : nil,
            schema: supports?(:json_schema) ? response_schema : nil,
            reasoning: reasoning
          )

          # Update chat with response data
          update_chat_with_response(provider_response)

          # Process and persist the result
          process_and_persist(provider_response)
        rescue => e
          Services::Ai::Result.new(success: false, error: e.message)
        end

        private

        attr_reader :parent, :provider, :chat, :role

        # Which entry of config.x.ai.roles this task runs on. Override in
        # subclasses; see config/initializers/ai.rb for what each role means.
        def task_role = :fast

        # Escape hatches: an explicit provider or model here beats the role.
        # No task in app/ overrides task_model any more.
        def task_provider  # e.g., :openai
          nil
        end

        def task_model
          nil
        end

        def chat_type = :analysis

        def system_message
          nil
        end

        def user_prompt
          raise
        end

        def response_format
          nil
        end

        def response_schema
          nil
        end

        def temperature
          1.0
        end

        def reasoning
          nil
        end

        def process_and_persist(raw) = raw

        def create_provider(key)
          case key&.to_sym
          when :openai
            Services::Ai::Providers::OpenaiStrategy.new
          # when :anthropic
          #   Services::Ai::Providers::AnthropicStrategy.new
          # when :gemini
          #   Services::Ai::Providers::GeminiStrategy.new
          else
            raise ArgumentError, "Unknown provider: #{key.inspect}"
          end
        end

        def validate!(raw_json)
          schema = response_schema
          return JSON.parse(raw_json, symbolize_names: true) unless schema
          data = JSON.parse(raw_json, symbolize_names: true)
          schema.new.validate!(data)
          data
        end

        def validate_parent!
          raise ArgumentError, "Parent is required" unless parent
        end

        def create_result(success:, data: nil, error: nil, ai_chat: nil)
          Services::Ai::Result.new(success: success, data: data, error: error, ai_chat: ai_chat)
        end

        def create_chat!
          AiChat.create!(
            parent: parent,
            chat_type: chat_type,
            model: @model,
            provider: @provider.provider_key,
            temperature: temperature,
            json_mode: response_format&.dig(:type) == "json_object",
            response_schema: response_schema ? schema_to_json(response_schema) : nil,
            messages: system_message ? [{role: "system", content: system_message, timestamp: Time.current}] : []
          )
        end

        def schema_to_json(schema)
          schema.to_json_schema.to_json
        end

        def add_user_message(content)
          @chat.messages ||= []
          @chat.messages << {role: "user", content: content, timestamp: Time.current}
          @chat.save!
        end

        def update_chat_with_response(provider_response)
          @chat.messages ||= []
          @chat.messages << {role: "assistant", content: provider_response[:content], timestamp: Time.current}
          @chat.raw_responses ||= []
          @chat.raw_responses << provider_response.merge(timestamp: Time.current)
          @chat.save!
        end
      end
    end
  end
end
```

Keep the existing comments in the file where they are not shown above (the file's `case` comment block may already list anthropic/gemini; keep whichever wording is there).

In `web-app/app/lib/services/ai/providers/openai_strategy.rb` change

```ruby
  def default_model = "gpt-5-mini"
```

to

```ruby
  # Only reached when a caller passes a provider without going through a task
  # role; tasks always resolve their model from Services::Ai::Roles.
  def default_model = Services::Ai::Roles.resolve(:fast).model
```

- [ ] **Step 6: Move every task from `task_model` to `task_role`**

In each of these files, replace the line `def task_model = "gpt-5-mini"` with the line shown. The two description tasks go to `standard` (they need recall); everything else is classification or extraction and goes to `fast`.

| File | Replacement line |
|---|---|
| `app/lib/services/ai/tasks/lists/base_raw_parser_task.rb:22` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/amazon_product_match_task.rb:20` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb:21` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/lists/music/albums/items_json_validator_task.rb:12` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb:20` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/games/igdb_search_match_task.rb:21` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb:20` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb:12` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/music/songs/recording_matcher_task.rb:20` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/matching/select_candidate_task.rb:32` | `def task_role = :fast` |
| `app/lib/services/ai/tasks/music/album_description_task.rb:10` | `def task_role = :standard` |
| `app/lib/services/ai/tasks/music/artist_description_task.rb:10` | `def task_role = :standard` |

Then confirm nothing is left:

Run: `cd web-app && grep -rn "gpt-5-mini\|task_model =" app`
Expected: no output.

- [ ] **Step 7: Update the tests that asserted the model**

In each file, the old test is

```ruby
test "task_model returns gpt-5-mini" do
  assert_equal "gpt-5-mini", @task.send(:task_model)
end
```

Replace with (indentation as the file has it):

```ruby
test "task_role is fast" do
  assert_equal :fast, @task.send(:task_role)
end
```

Files taking the `:fast` version: `test/lib/services/ai/tasks/lists/music/albums/items_json_validator_task_test.rb:49`, `test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb:57`, `test/lib/services/ai/tasks/lists/music/songs/items_json_validator_task_test.rb:49`, `test/lib/services/ai/tasks/lists/music/albums/list_items_validator_task_test.rb:57`, `test/lib/services/ai/tasks/music/songs/recording_matcher_task_test.rb:41`, `test/lib/services/ai/tasks/amazon_album_match_task_test.rb:20`.

Files with a differently named test, same replacement body:
- `test/lib/services/ai/tasks/games/amazon_game_match_task_test.rb:116` and `test/lib/services/ai/tasks/games/igdb_search_match_task_test.rb:77`: `test "uses gpt-5-mini model"` becomes `test "uses the fast role"` with `assert_equal :fast, @task.send(:task_role)`.
- `test/lib/services/ai/tasks/amazon_product_match_task_test.rb:53`: `assert_equal "gpt-5-mini", task.send(:task_model)` becomes `assert_equal :fast, task.send(:task_role)`.
- `test/lib/services/ai/tasks/matching/select_candidate_task_test.rb:24-26`: rename the test to `"uses the fast role on openai with json mode"` and change line 26 to `assert_equal :fast, @task.send(:task_role)`.
- `test/lib/services/ai/tasks/album_description_task_test.rb:19` and `test/lib/services/ai/tasks/artist_description_task_test.rb:19`: become `test "task_role is standard"` with `assert_equal :standard, @task.send(:task_role)`.
- `test/lib/services/ai/providers/openai_strategy_test.rb:23`: `assert_equal "gpt-5-mini", @strategy.default_model` becomes `assert_equal "gpt-6-luna", @strategy.default_model`.

Add to `web-app/test/lib/services/ai/tasks/base_task_test.rb`, inside the class after the `"should have default temperature"` test:

```ruby
        test "model comes from the task role when none is given" do
          assert_equal "gpt-6-sol", @task.instance_variable_get(:@model)
        end

        test "an explicit model beats the role" do
          task = Music::ArtistDescriptionTask.new(parent: @artist, model: "gpt-4o")
          assert_equal "gpt-4o", task.instance_variable_get(:@model)
        end

        class UnknownRoleTask < BaseTask
          private

          def task_role = :nope

          def user_prompt = "irrelevant"
        end

        test "an unknown role raises at construction" do
          assert_raises(Services::Ai::Roles::UnknownRole) { UnknownRoleTask.new(parent: @artist) }
        end
```

- [ ] **Step 8: Run the AI test tree and lint**

Run: `cd web-app && bin/rails test test/lib/services/ai && bundle exec standardrb app/lib/services/ai config/initializers/ai.rb test/lib/services/ai`
Expected: all green, no lint output.

- [ ] **Step 9: Commit**

```bash
git add web-app/config/initializers/ai.rb web-app/app/lib/services/ai web-app/test/lib/services/ai
git commit -m "AI tasks declare a model role; roles map to models in config

Retires the hardcoded gpt-5-mini (OpenAI shutdown 2026-12-11) from all 13
tasks. Match, parsing and Amazon tasks run on fast (gpt-6-luna); the two
music description tasks on standard (gpt-6-sol)."
```

---

### Task 2: Web search tool and citations on `OpenaiStrategy`

**Files:**
- Modify: `web-app/app/lib/services/ai/tasks/base_task.rb` (`call`, add `tools`, `force_tool?`)
- Modify: `web-app/app/lib/services/ai/providers/base_strategy.rb`
- Modify: `web-app/app/lib/services/ai/providers/openai_strategy.rb`
- Modify: `web-app/test/lib/services/ai/providers/openai_strategy_test.rb`
- Modify: `web-app/test/lib/services/ai/tasks/base_task_test.rb:51-57`

**Interfaces:**
- Consumes: `Services::Ai::Roles::Role#tools` from Task 1.
- Produces: `BaseTask#tools` (private, default `role.tools`), `BaseTask#force_tool?` (private, default false).
- Produces: `send_message!(ai_chat:, content:, response_format:, schema:, reasoning: nil, tools: [], force_tool: false)` on every strategy.
- Produces: the provider response hash gains `citations: Array<String>` and `web_search_calls: Integer`.

- [ ] **Step 1: Write the failing strategy tests**

Add to `web-app/test/lib/services/ai/providers/openai_strategy_test.rb`, before the `private` line:

```ruby
  test "sends the web_search tool when a task asks for it" do
    mock_response = create_mock_response({ok: true})

    @mock_responses.expects(:create).with(
      {
        model: @ai_chat.model,
        input: [{role: "user", content: "Hello"}, {role: "user", content: @content}],
        temperature: @ai_chat.temperature.to_f,
        service_tier: "flex",
        tools: [{type: "web_search", search_context_size: "low"}]
      }
    ).returns(mock_response)

    @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search])
  end

  test "forces the tool with tool_choice when asked" do
    mock_response = create_mock_response({ok: true})

    @mock_responses.expects(:create).with(
      has_entries(
        tools: [{type: "web_search", search_context_size: "low"}],
        tool_choice: {type: "web_search"}
      )
    ).returns(mock_response)

    @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search], force_tool: true)
  end

  test "an unknown tool raises before any request is made" do
    @mock_responses.expects(:create).never

    assert_raises(ArgumentError) do
      @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:teleport])
    end
  end

  test "returns no citations and zero web search calls for a plain response" do
    @mock_responses.stubs(:create).returns(create_mock_response({ok: true}))

    result = @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil)

    assert_equal [], result[:citations]
    assert_equal 0, result[:web_search_calls]
  end

  test "extracts url citations, strips utm_source and de-duplicates" do
    annotation_a = mock
    annotation_a.stubs(:type).returns(:url_citation)
    annotation_a.stubs(:url).returns("https://example.org/book?utm_source=openai")
    annotation_b = mock
    annotation_b.stubs(:type).returns(:url_citation)
    annotation_b.stubs(:url).returns("https://example.org/book?utm_source=openai")
    annotation_c = mock
    annotation_c.stubs(:type).returns(:url_citation)
    annotation_c.stubs(:url).returns("https://example.org/other?page=2&utm_source=openai")
    file_annotation = mock
    file_annotation.stubs(:type).returns(:file_citation)

    mock_response = create_mock_response({ok: true}, annotations: [annotation_a, annotation_b, annotation_c, file_annotation], web_search_calls: 2)
    @mock_responses.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search])

    assert_equal ["https://example.org/book", "https://example.org/other?page=2"], result[:citations]
    assert_equal 2, result[:web_search_calls]
  end
```

Replace the existing `create_mock_response` helper at the bottom of the file with:

```ruby
  def create_mock_response(parsed_data, annotations: nil, web_search_calls: 0)
    mock_content = mock
    mock_content.stubs(:text).returns(parsed_data.to_json)
    mock_content.stubs(:parsed).returns(parsed_data)
    # A content item without annotations (older SDK shapes, or a message with
    # none) must not raise; only stub the method when the test supplies some.
    mock_content.stubs(:annotations).returns(annotations) unless annotations.nil?

    mock_message_item = mock
    mock_message_item.stubs(:type).returns(:message)
    mock_message_item.stubs(:content).returns([mock_content])

    search_items = Array.new(web_search_calls) do
      item = mock
      item.stubs(:type).returns(:web_search_call)
      item
    end

    mock_response = mock
    usage_hash = {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    mock_response.stubs(:output).returns(search_items + [mock_message_item])
    mock_response.stubs(:id).returns("resp-123")
    mock_response.stubs(:model).returns("gpt-5-mini")
    mock_response.stubs(:usage).returns(usage_hash)

    mock_response
  end
```

(The mock's model string is test data, not an app model choice; leave it.)

- [ ] **Step 2: Run to verify failure**

Run: `cd web-app && bin/rails test test/lib/services/ai/providers/openai_strategy_test.rb`
Expected: the five new tests FAIL (`unknown keyword: :tools`, missing `:citations`).

- [ ] **Step 3: Implement the plumbing**

`web-app/app/lib/services/ai/providers/base_strategy.rb`, replace `send_message!` and `build_parameters`:

```ruby
        def send_message!(ai_chat:, content:, response_format:, schema:, reasoning: nil, tools: [], force_tool: false)
          messages = ai_chat.messages + [{role: "user", content: content}]
          parameters = build_parameters(
            model: ai_chat.model, messages: messages, temperature: ai_chat.temperature.to_f,
            response_format: response_format, schema: schema, reasoning: reasoning,
            tools: tools, force_tool: force_tool
          )
          # Save parameters to ai_chat BEFORE making API call
          ai_chat.parameters = parameters
          ai_chat.save!
          response = make_api_call(parameters)
          format_response(response, schema)
        end
```

```ruby
        def build_parameters(model:, messages:, temperature:, response_format:, schema:, reasoning: nil, tools: [], force_tool: false)
          {model: model, messages: messages, temperature: temperature}
        end
```

`web-app/app/lib/services/ai/providers/openai_strategy.rb`, full file:

```ruby
class Services::Ai::Providers::OpenaiStrategy < Services::Ai::Providers::BaseStrategy
  # Responses API tool definitions by the symbol a task uses. `low` context is
  # the cheapest search tier; the enrichment probe got two citations from it.
  TOOL_DEFINITIONS = {
    web_search: {type: "web_search", search_context_size: "low"}
  }.freeze

  def capabilities = %i[json_mode json_schema function_calls]

  # Only reached when a caller passes a provider without going through a task
  # role; tasks always resolve their model from Services::Ai::Roles.
  def default_model = Services::Ai::Roles.resolve(:fast).model

  def provider_key = :openai

  protected

  def client
    @client ||= OpenAI::Client.new
  end

  def make_api_call(parameters)
    client.responses.create(parameters)
  end

  def format_response(response, schema)
    # output is an array that may contain reasoning, message, web_search_call and tool_call items
    web_search_calls = response.output.count { |item| item.type.to_s == "web_search_call" }
    message_item = response.output.find { |item| item.type == :message }

    unless message_item
      tool_calls = response.output.select { |item| item.type == :tool_call }
      if tool_calls.any?
        return {
          content: nil,
          parsed: nil,
          tool_calls: tool_calls.map { |tc| {id: tc.id, name: tc.name, arguments: tc.arguments} },
          citations: [],
          web_search_calls: web_search_calls,
          id: response.id,
          model: response.model,
          usage: response.usage
        }
      else
        raise "OpenAI response contains neither message nor tool_call items"
      end
    end

    content_item = message_item.content.first
    parsed_data = if content_item.respond_to?(:parsed) && !content_item.parsed.nil?
      content_item.parsed.to_h.deep_symbolize_keys
    else
      parse_response(content_item.text, schema)
    end

    {
      content: content_item.text,
      parsed: parsed_data,
      citations: extract_citations(content_item),
      web_search_calls: web_search_calls,
      id: response.id,
      model: response.model,
      usage: response.usage
    }
  end

  def build_parameters(model:, messages:, temperature:, response_format:, schema:, reasoning: nil, tools: [], force_tool: false)
    system_messages = messages.select { |m| (m[:role] || m["role"]) == "system" }
    conversation_messages = messages.reject { |m| (m[:role] || m["role"]) == "system" }
    clean_messages = conversation_messages.map { |msg| {role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]} }

    parameters = {model: model, temperature: temperature, service_tier: "flex"}

    if system_messages.any?
      parameters[:instructions] = system_messages.first[:content] || system_messages.first["content"]
    end

    parameters[:input] = (clean_messages.length == 1 && clean_messages.first[:role] == "user") ? clean_messages.first[:content] : clean_messages
    parameters[:reasoning] = reasoning if reasoning

    if schema && schema < OpenAI::BaseModel
      parameters[:text] = schema
    elsif response_format
      parameters[:response_format] = response_format
    end

    definitions = tools.map { |tool| tool_definition(tool) }
    if definitions.any?
      parameters[:tools] = definitions
      parameters[:tool_choice] = {type: definitions.first[:type]} if force_tool
    end

    parameters
  end

  private

  def tool_definition(tool)
    TOOL_DEFINITIONS.fetch(tool.to_sym) { raise ArgumentError, "Unknown AI tool: #{tool.inspect}" }
  end

  # url_citation annotations from the message, in order, de-duplicated, with
  # the tracking parameter OpenAI appends removed. A content item with no
  # annotations method (a mock, an older SDK shape) yields [].
  def extract_citations(content_item)
    return [] unless content_item.respond_to?(:annotations)

    Array(content_item.annotations)
      .select { |annotation| annotation.type.to_s == "url_citation" && annotation.respond_to?(:url) }
      .map { |annotation| strip_tracking(annotation.url.to_s) }
      .uniq
  end

  def strip_tracking(url)
    uri = URI.parse(url)
    return url if uri.query.blank?

    params = URI.decode_www_form(uri.query).reject { |key, _| key == "utm_source" }
    uri.query = params.empty? ? nil : URI.encode_www_form(params)
    uri.to_s
  rescue URI::InvalidURIError
    url
  end
end
```

Note: `build_parameters` was `protected` in the original and stays so; the two new helpers are `private`.

`web-app/app/lib/services/ai/tasks/base_task.rb`: in `call`, change the `send_message!` invocation to

```ruby
          provider_response = @provider.send_message!(
            ai_chat: @chat,
            content: user_content,
            response_format: supports?(:json_mode) ? response_format : nil,
            schema: supports?(:json_schema) ? response_schema : nil,
            reasoning: reasoning,
            tools: tools,
            force_tool: force_tool?
          )
```

and add, under `private` after `def task_role = :fast`:

```ruby
        # Tools the provider should offer the model. The role supplies them
        # (research carries :web_search); a task may override to add its own.
        def tools = role.tools

        # When true the provider requires the first tool to be used.
        def force_tool? = false
```

- [ ] **Step 4: Update the exact expectation in `base_task_test.rb`**

Lines 51-57 become:

```ruby
          @mock_strategy.expects(:send_message!).with(
            ai_chat: mock_chat,
            content: kind_of(String),
            response_format: {type: "json_object"},
            schema: Music::ArtistDescriptionTask::ResponseSchema,
            reasoning: nil,
            tools: [],
            force_tool: false
          ).returns(mock_provider_response)
```

- [ ] **Step 5: Run and lint**

Run: `cd web-app && bin/rails test test/lib/services/ai && bundle exec standardrb app/lib/services/ai test/lib/services/ai`
Expected: green, no lint output.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/services/ai web-app/test/lib/services/ai
git commit -m "OpenAI strategy sends the web_search tool and returns citations

Tasks expose tools (from their role) and force_tool?; the strategy maps
:web_search to the Responses API definition, forces it via tool_choice
when asked, and returns url_citation URLs with utm_source stripped."
```

---

### Task 3: The `enrichments` ledger

**Files:**
- Create (generator): `web-app/db/migrate/<timestamp>_create_enrichments.rb`, `web-app/app/models/enrichment.rb`, `web-app/test/models/enrichment_test.rb`, `web-app/test/fixtures/enrichments.yml`
- Modify: `web-app/app/models/books/book.rb:105` (association)
- Modify: `web-app/app/lib/books/book/merger.rb:124-146` and `:164-166`
- Modify: `web-app/test/lib/books/book/merger_test.rb` (add a test)
- Modify: `web-app/db/schema.rb` (by `db:migrate`)

**Interfaces:**
- Produces: `Enrichment` with enums `mode {knowledge: 0, research: 1}`, `outcome {applied: 0, nothing_to_apply: 1, unrecognized: 2, skipped: 3, failed: 4}`, `confidence {high: 0, medium: 1, low: 2}` (prefix `confidence_`), columns `kind`, `recognized`, `facts` (jsonb), `citations` (jsonb array), `provider`, `model`, `ai_chat_id`, `error`, `reason`. Scopes `for_kind(kind)`, `today`, `low_confidence_on(fact)`, plus the enum scopes (`Enrichment.research`).
- Produces: `Books::Book#enrichments`.

- [ ] **Step 1: Generate the model**

Run:

```bash
cd web-app && bin/rails generate model Enrichment enrichable:references{polymorphic} kind:string mode:integer outcome:integer recognized:boolean confidence:integer facts:jsonb citations:jsonb provider:string model:string ai_chat:references error:text reason:string
```

Expected: a migration, `app/models/enrichment.rb`, `test/models/enrichment_test.rb`, `test/fixtures/enrichments.yml`.

- [ ] **Step 2: Replace the migration body**

```ruby
class CreateEnrichments < ActiveRecord::Migration[8.1]
  def change
    create_table :enrichments do |t|
      # One row per AI enrichment run on any record, across domains, like
      # ai_chats. Spec: docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §3.
      t.references :enrichable, polymorphic: true, null: false
      t.string :kind, null: false
      t.integer :mode, null: false, default: 0
      t.integer :outcome, null: false
      t.boolean :recognized
      t.integer :confidence
      t.jsonb :facts, null: false, default: {}
      t.jsonb :citations, null: false, default: []
      t.string :provider
      t.string :model
      # Nullable: a skipped run has no chat. Nullify, not cascade: the ledger
      # outlives the chat that produced it.
      t.references :ai_chat, null: true, foreign_key: {on_delete: :nullify}
      t.text :error
      t.string :reason

      t.timestamps
    end

    add_index :enrichments, :kind
    add_index :enrichments, :outcome
    # The research budget is "research rows created today"; this serves it.
    add_index :enrichments, [:mode, :created_at]
  end
end
```

Run: `cd web-app && bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate`
Expected: both succeed; `db/schema.rb` gains `create_table "enrichments"`.

- [ ] **Step 3: Write the failing model test**

Replace `web-app/test/models/enrichment_test.rb`:

```ruby
require "test_helper"

class EnrichmentTest < ActiveSupport::TestCase
  test "fixtures cover every outcome" do
    assert_equal Enrichment.outcomes.keys.sort, Enrichment.distinct.pluck(:outcome).sort
  end

  test "belongs to a polymorphic enrichable" do
    row = enrichments(:war_and_peace_facts_applied)
    assert_equal books_books(:war_and_peace), row.enrichable
  end

  test "requires a namespaced kind" do
    row = Enrichment.new(enrichable: books_books(:war_and_peace), kind: "book_facts", outcome: :applied)
    assert_not row.valid?
    assert_includes row.errors[:kind], "is invalid"

    row.kind = "books.book_facts"
    assert row.valid?
  end

  test "ai_chat is optional" do
    row = enrichments(:crime_and_punishment_research_skipped)
    assert_nil row.ai_chat
    assert row.valid?
  end

  test "for_kind scopes by kind" do
    assert_includes Enrichment.for_kind("books.book_facts"), enrichments(:war_and_peace_facts_applied)
    assert_empty Enrichment.for_kind("music.album_facts")
  end

  test "today excludes rows created before midnight" do
    assert_includes Enrichment.today, enrichments(:crime_and_punishment_research_skipped)
    assert_not_includes Enrichment.today, enrichments(:war_and_peace_research_old)
  end

  test "research scope combines with today for the budget count" do
    assert_equal 1, Enrichment.research.today.count
  end

  test "low_confidence_on finds rows by a fact's confidence" do
    assert_includes Enrichment.low_confidence_on(:word_count), enrichments(:war_and_peace_facts_applied)
    assert_not_includes Enrichment.low_confidence_on(:first_published_year), enrichments(:war_and_peace_facts_applied)
  end

  test "confidence enum is prefixed" do
    assert enrichments(:war_and_peace_facts_applied).confidence_high?
    assert enrichments(:crime_and_punishment_unrecognized).confidence_low?
  end
end
```

Replace `web-app/test/fixtures/enrichments.yml` (keep the annotate header the generator or annotaterb adds above it, if any):

```yaml
# One row per outcome and per mode, so a scope that returns nothing has
# something it could have returned.

war_and_peace_facts_applied:
  enrichable: war_and_peace (Books::Book)
  kind: books.book_facts
  mode: knowledge
  outcome: applied
  recognized: true
  confidence: high
  facts:
    first_published_year: {value: 1869, confidence: high, applied: false, reason: already_set}
    word_count: {value: 587287, confidence: low, applied: true, reason: filled}
  provider: openai
  model: gpt-6-sol

crime_and_punishment_unrecognized:
  enrichable: crime_and_punishment (Books::Book)
  kind: books.book_facts
  mode: knowledge
  outcome: unrecognized
  recognized: false
  confidence: low
  provider: openai
  model: gpt-6-sol

crime_and_punishment_research_skipped:
  enrichable: crime_and_punishment (Books::Book)
  kind: books.book_facts
  mode: research
  outcome: skipped
  reason: budget_exhausted

combo_steinbeck_failed:
  enrichable: combo_steinbeck (Books::Book)
  kind: books.book_facts
  mode: knowledge
  outcome: failed
  error: "OpenAI timeout"
  provider: openai
  model: gpt-6-sol

war_and_peace_research_old:
  enrichable: war_and_peace (Books::Book)
  kind: books.book_facts
  mode: research
  outcome: nothing_to_apply
  recognized: true
  confidence: medium
  citations: ["https://example.org/war-and-peace"]
  provider: openai
  model: gpt-6-astra
  created_at: 2020-01-01 00:00:00
  updated_at: 2020-01-01 00:00:00
```

- [ ] **Step 4: Run to verify failure**

Run: `cd web-app && bin/rails test test/models/enrichment_test.rb`
Expected: FAIL (enums and scopes undefined, kind validation missing).

- [ ] **Step 5: Write the model**

`web-app/app/models/enrichment.rb`:

```ruby
# One AI enrichment run on one record. The audit trail and the backlog: which
# model said what about which field, with what confidence, and whether it was
# applied. Skipped and failed runs get a row too.
class Enrichment < ApplicationRecord
  KIND_FORMAT = /\A[a-z_]+\.[a-z_]+\z/

  belongs_to :enrichable, polymorphic: true
  belongs_to :ai_chat, optional: true

  enum :mode, {knowledge: 0, research: 1}
  enum :outcome, {applied: 0, nothing_to_apply: 1, unrecognized: 2, skipped: 3, failed: 4}
  enum :confidence, {high: 0, medium: 1, low: 2}, prefix: true

  validates :kind, presence: true, format: {with: KIND_FORMAT}

  scope :for_kind, ->(kind) { where(kind: kind) }
  scope :today, -> { where(created_at: Time.current.beginning_of_day..) }
  scope :low_confidence_on, ->(fact) { where("facts -> ? ->> 'confidence' = 'low'", fact.to_s) }
end
```

- [ ] **Step 6: Run the model test**

Run: `cd web-app && bin/rails test test/models/enrichment_test.rb`
Expected: 9 runs, 0 failures.

- [ ] **Step 7: Association and merger, test first**

Add to `web-app/test/lib/books/book/merger_test.rb`, right after the `"moves ai chats to the target"` test:

```ruby
      test "moves enrichments to the target" do
        row = Enrichment.create!(enrichable: @source, kind: "books.book_facts", outcome: :nothing_to_apply)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, row.reload.enrichable_id
        assert_equal "Books::Book", row.enrichable_type
      end
```

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb -n /enrichments/`
Expected: FAIL (`@source.enrichments` undefined, or the row is destroyed with the source).

In `web-app/app/models/books/book.rb`, after line 105 (`has_many :ai_chats, ...`) add:

```ruby
  has_many :enrichments, as: :enrichable, dependent: :destroy
```

In `web-app/app/lib/books/book/merger.rb`, in `merge_all_associations` add `merge_enrichments` on the line after `merge_ai_chats`, and after the `merge_ai_chats` method add:

```ruby
      def merge_enrichments
        @stats[:enrichments] = source_book.enrichments.update_all(enrichable_id: target_book.id)
      end
```

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb test/models/books`
Expected: green.

- [ ] **Step 8: Lint and commit**

Run: `cd web-app && bundle exec standardrb app/models/enrichment.rb app/models/books/book.rb app/lib/books/book/merger.rb test/models/enrichment_test.rb test/lib/books/book/merger_test.rb db/migrate`

```bash
git add web-app/db web-app/app/models web-app/app/lib/books/book/merger.rb web-app/test/models/enrichment_test.rb web-app/test/fixtures/enrichments.yml web-app/test/lib/books/book/merger_test.rb
git commit -m "Add the enrichments ledger: one row per AI enrichment run

Polymorphic like ai_chats. Books::Book has_many and the merger moves
rows to the surviving book."
```

---

### Task 4: `EnrichmentTask` base and `Books::BookFactsTask`

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/enrichment_task.rb`
- Create: `web-app/app/lib/services/ai/tasks/books/book_facts_task.rb`
- Create: `web-app/test/lib/services/ai/tasks/enrichment_task_test.rb`
- Create: `web-app/test/lib/services/ai/tasks/books/book_facts_task_test.rb`

**Interfaces:**
- Consumes: `BaseTask#task_role`, `#tools`, `#force_tool?` (Tasks 1–2); provider response `:citations` (Task 2).
- Produces: `Services::Ai::Tasks::EnrichmentTask.new(parent:, mode: :knowledge, provider: nil, model: nil)`, `#mode`, `#research?`. `MODES = %i[knowledge research]`. Nested schema helpers `EnrichmentTask::IntegerFact`, `StringFact`, `StringListFact` (each `value` + `confidence`).
- Produces: `Services::Ai::Tasks::Books::BookFactsTask.new(parent: book, mode:, author_names: nil)`. `#call` returns `Services::Ai::Result` whose `data` is `{facts: Hash, citations: Array<String>}` where `facts` is the parsed schema hash with symbol keys: `recognized`, `confidence`, `first_published_year_estimated` at top level, every other fact as `{value:, confidence:}`. Writes nothing to the book.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/ai/tasks/enrichment_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      class EnrichmentTaskTest < ActiveSupport::TestCase
        class ProbeTask < EnrichmentTask
          private

          def user_prompt = "probe"

          def response_schema = Schema

          class Schema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean
            required :confidence, String
            required :year, EnrichmentTask::IntegerFact
          end
        end

        def setup
          @book = books_books(:war_and_peace)
        end

        test "defaults to knowledge mode on the standard role with no tools" do
          task = ProbeTask.new(parent: @book)

          assert_equal :knowledge, task.mode
          refute task.research?
          assert_equal :standard, task.send(:task_role)
          assert_equal [], task.send(:tools)
          refute task.send(:force_tool?)
          assert_equal "gpt-6-sol", task.instance_variable_get(:@model)
        end

        test "research mode runs on the research role and forces web search" do
          task = ProbeTask.new(parent: @book, mode: :research)

          assert task.research?
          assert_equal :research, task.send(:task_role)
          assert_equal [:web_search], task.send(:tools)
          assert task.send(:force_tool?)
          assert_equal "gpt-6-astra", task.instance_variable_get(:@model)
        end

        test "rejects an unknown mode" do
          assert_raises(ArgumentError) { ProbeTask.new(parent: @book, mode: :guess) }
        end

        test "process_and_persist returns facts and citations and writes nothing" do
          task = ProbeTask.new(parent: @book)
          task.stubs(:chat).returns(ai_chats(:general_chat))
          before = @book.attributes

          result = task.send(:process_and_persist, {parsed: {recognized: true, confidence: "high", year: {value: 1869, confidence: "high"}}, citations: ["https://example.org"]})

          assert result.success?
          assert_equal({recognized: true, confidence: "high", year: {value: 1869, confidence: "high"}}, result.data[:facts])
          assert_equal ["https://example.org"], result.data[:citations]
          assert_equal ai_chats(:general_chat), result.ai_chat
          assert_equal before, @book.reload.attributes
        end

        test "process_and_persist tolerates a response without citations" do
          task = ProbeTask.new(parent: @book)
          task.stubs(:chat).returns(ai_chats(:general_chat))

          result = task.send(:process_and_persist, {parsed: {recognized: false, confidence: "low", year: {value: nil, confidence: "low"}}})

          assert_equal [], result.data[:citations]
        end

        test "fact schemas expose value and confidence" do
          schema = EnrichmentTask::IntegerFact.to_json_schema
          assert_equal %w[value confidence], schema[:properties].keys.map(&:to_s)
        end
      end
    end
  end
end
```

`web-app/test/lib/services/ai/tasks/books/book_facts_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class BookFactsTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
          end

          test "runs on openai as an analysis chat with json mode" do
            task = BookFactsTask.new(parent: @book)

            assert_equal :openai, task.send(:provider).provider_key
            assert_equal :analysis, task.send(:chat_type)
            assert_equal({type: "json_object"}, task.send(:response_format))
            assert_equal BookFactsTask::ResponseSchema, task.send(:response_schema)
          end

          test "the schema is a class-level json schema with every fact" do
            keys = BookFactsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)

            %w[recognized confidence first_published_year first_published_year_estimated original_language
              word_count page_range subtitle alternate_titles origin_countries book_type series_name
              series_number description].each do |key|
              assert_includes keys, key
            end
          end

          test "user prompt names the book, its authors and known year" do
            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "War and Peace"
            assert_includes prompt, "Leo Tolstoy"
            assert_includes prompt, "1869"
          end

          test "user prompt uses passed author names when the book has none" do
            book = ::Books::Book.create!(title: "An Unattributed Work")
            prompt = BookFactsTask.new(parent: book, author_names: ["Someone Obscure"]).send(:user_prompt)

            assert_includes prompt, "Someone Obscure"
          end

          test "user prompt includes identifiers when present" do
            @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780140447934")
            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "9780140447934"
          end

          test "user prompt marks an existing description as context only" do
            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "context only"
            assert_includes prompt, @book.primary_description.content
          end

          test "system message carries the description rules" do
            message = BookFactsTask.new(parent: @book).send(:system_message)

            assert_includes message, "Spoiler-free"
            assert_includes message, "60 to 110 words"
            assert_includes message, "em dashes"
            assert_includes message, "No citations, URLs"
          end

          test "research mode tells the model to verify with web search" do
            knowledge = BookFactsTask.new(parent: @book).send(:system_message)
            research = BookFactsTask.new(parent: @book, mode: :research).send(:system_message)

            refute_includes knowledge, "web search"
            assert_includes research, "web search"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web-app && bin/rails test test/lib/services/ai/tasks/enrichment_task_test.rb test/lib/services/ai/tasks/books/book_facts_task_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Ai::Tasks::EnrichmentTask`.

- [ ] **Step 3: Write `EnrichmentTask`**

`web-app/app/lib/services/ai/tasks/enrichment_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      # A task that reports facts about its parent without writing them. The
      # runner hands the parsed facts to an applier, which owns the write
      # policy; this class owns the prompt, the schema and the mode.
      #
      # mode :knowledge asks the model what it knows (the standard role);
      # mode :research forces a web search first (the research role).
      class EnrichmentTask < BaseTask
        MODES = %i[knowledge research].freeze
        CONFIDENCES = %w[high medium low].freeze

        class IntegerFact < OpenAI::BaseModel
          required :value, Integer, nil?: true, doc: "The value, or null when unknown"
          required :confidence, String, doc: "high, medium or low"
        end

        class StringFact < OpenAI::BaseModel
          required :value, String, nil?: true, doc: "The value, or null when unknown"
          required :confidence, String, doc: "high, medium or low"
        end

        class StringListFact < OpenAI::BaseModel
          required :value, OpenAI::ArrayOf[String], doc: "The values; an empty list when unknown"
          required :confidence, String, doc: "high, medium or low"
        end

        attr_reader :mode

        def initialize(parent:, mode: :knowledge, provider: nil, model: nil)
          unless MODES.include?(mode)
            raise ArgumentError, "mode must be one of #{MODES.join(", ")}, got #{mode.inspect}"
          end

          @mode = mode
          super(parent: parent, provider: provider, model: model)
        end

        def research? = mode == :research

        private

        def task_role = research? ? :research : knowledge_role

        # Override for a task whose knowledge call does not need recall.
        def knowledge_role = :standard

        def force_tool? = research?

        def response_format = {type: "json_object"}

        def process_and_persist(provider_response)
          Services::Ai::Result.new(
            success: true,
            data: {facts: provider_response[:parsed], citations: Array(provider_response[:citations])},
            ai_chat: chat
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Write `BookFactsTask`**

`web-app/app/lib/services/ai/tasks/books/book_facts_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      module Books
        # Facts and a description for one Books::Book in a single call. Both
        # depend on whether the model knows the book, and `recognized`
        # governs both. Applied by Services::Books::ApplyBookFacts.
        class BookFactsTask < EnrichmentTask
          IDENTIFIER_LABELS = {
            "books_work_isbn13" => "ISBN-13",
            "books_work_openlibrary_id" => "Open Library work key"
          }.freeze

          def initialize(parent:, mode: :knowledge, author_names: nil, provider: nil, model: nil)
            @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
            super(parent: parent, mode: mode, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def author_names
            @author_names.presence || parent.authors.map(&:name)
          end

          def system_message
            <<~SYSTEM_MESSAGE
              You are a bibliographic researcher for a book catalog. You report facts about one book and write one short description of it.#{research_instruction}

              Facts. For every fact give a value and a confidence of high, medium or low. Use null (or an empty list) when you do not know; never guess. Set "recognized" to false if you do not know this specific book, and give an overall "confidence" for how well you know it. first_published_year is the year the work was first published in any language; set first_published_year_estimated when the year is approximate. original_language is the language the work was written in, as an ISO 639-1 code such as "en" or "ru". word_count is the approximate length of the full text. page_range is a typical page count for a standard edition, as "300" or "250-350". alternate_titles are other titles the same work has been published under, including translated titles. origin_countries are the nationalities of the work or its author, as English nationality adjectives such as "French" or "Japanese". book_type is one of fiction, nonfiction, poetry, religious. series_name and series_number are set only when the book is part of a series.

              Description rules.
              - Spoiler-free. Describe the premise, the setting, and the situation the book opens on. Never reveal twists, deaths, endings, or how the central question resolves. For nonfiction, describe the subject and the argument, not the conclusions.
              - One paragraph, 60 to 110 words, sentences of varied length. Do not name the title or the author; the page shows both.
              - No em dashes or double hyphens, no semicolons, no lists, no emoji, no quotation marks around titles.
              - No marketing or judgment: no acclaimed, bestselling, masterpiece, unforgettable, must-read, no awards, no sales figures.
              - No meta narration such as "This novel" or "Readers will". Open on the subject.
              - Plain words. Do not use: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, or "explores themes of".
              - No "not X but Y" constructions. No ornamental triads of adjectives.
              - Only what you are sure of. Say less rather than guess. If you do not know the book well enough to describe its premise, set description to null.
              - No citations, URLs, footnotes, or bracketed references inside any text field.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def research_instruction
            return "" unless research?

            " Use web search to verify every fact before reporting it; prefer publisher, library and encyclopedia sources. Report what the sources say, not what you remember."
          end

          def user_prompt
            lines = ["Book: \"#{parent.title}\""]
            lines << "Subtitle: #{parent.subtitle}" if parent.subtitle.present?
            lines << "Author(s): #{author_names.join(", ")}" if author_names.any?
            lines << "First published (our record): #{parent.first_published_year}" if parent.first_published_year.present?
            identifier_lines.each { |line| lines << line }

            existing = parent.primary_description&.content
            if existing.present?
              lines << "Our current description, for context only; do not copy or extend it: #{existing}"
            end

            lines << ""
            lines << "Report the facts and write the description as JSON matching the schema."
            lines.join("\n")
          end

          def identifier_lines
            parent.identifiers
              .where(identifier_type: IDENTIFIER_LABELS.keys)
              .pluck(:identifier_type, :value)
              .map { |type, value| "#{IDENTIFIER_LABELS.fetch(type)}: #{value}" }
          end

          def response_schema = ResponseSchema

          class ResponseSchema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean, doc: "false if you do not know this specific book"
            required :confidence, String, doc: "high, medium or low: how well you know this specific book"
            required :first_published_year, EnrichmentTask::IntegerFact
            required :first_published_year_estimated, OpenAI::Boolean, doc: "true when the year is approximate"
            required :original_language, EnrichmentTask::StringFact, doc: "ISO 639-1 code"
            required :word_count, EnrichmentTask::IntegerFact
            required :page_range, EnrichmentTask::StringFact, doc: "\"300\" or \"250-350\""
            required :subtitle, EnrichmentTask::StringFact
            required :alternate_titles, EnrichmentTask::StringListFact
            required :origin_countries, EnrichmentTask::StringListFact, doc: "English nationality adjectives"
            required :book_type, EnrichmentTask::StringFact, doc: "fiction, nonfiction, poetry or religious"
            required :series_name, EnrichmentTask::StringFact
            required :series_number, EnrichmentTask::IntegerFact
            required :description, EnrichmentTask::StringFact, doc: "One spoiler-free paragraph following the rules"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests and lint**

Run: `cd web-app && bin/rails test test/lib/services/ai/tasks/enrichment_task_test.rb test/lib/services/ai/tasks/books/book_facts_task_test.rb && bundle exec standardrb app/lib/services/ai/tasks test/lib/services/ai/tasks`
Expected: 14 runs, 0 failures; no lint output. If `to_json_schema[:properties]` uses string keys in this gem version, adjust the two schema tests to `.keys.map(&:to_s)` (already done) and index with the key type the gem returns.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/services/ai/tasks/enrichment_task.rb web-app/app/lib/services/ai/tasks/books/book_facts_task.rb web-app/test/lib/services/ai/tasks/enrichment_task_test.rb web-app/test/lib/services/ai/tasks/books/book_facts_task_test.rb
git commit -m "Add EnrichmentTask and Books::BookFactsTask

An enrichment task reports facts with per-field confidence and never
writes to its parent. BookFactsTask asks for a book's metadata and a
spoiler-free description in one call; research mode forces web search."
```

---

### Task 5: `Services::Books::ApplyBookFacts`

**Files:**
- Create: `web-app/app/lib/services/books/apply_book_facts.rb`
- Create: `web-app/test/lib/services/books/apply_book_facts_test.rb`

**Interfaces:**
- Consumes: the `facts` hash shape from Task 4.
- Produces: `Services::Books::ApplyBookFacts.call(book:, facts:, citations: [], description: nil) -> Result` with `data: {facts: Hash<String, Hash>, applied: Array<String>}`. `description` is `nil` or `{text: String, review: Hash|nil, reason: String|nil}`; when `reason` is present the text is not written. Ledger fact entries are `{"value" => ..., "confidence" => ..., "applied" => bool, "reason" => String}`; the description entry adds `"review"`, `origin_countries` adds `"unmatched"`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/apply_book_facts_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    class ApplyBookFactsTest < ActiveSupport::TestCase
      def setup
        @book = ::Books::Book.create!(title: "A Fresh Book")
      end

      def facts(overrides = {})
        {
          recognized: true,
          confidence: "high",
          first_published_year: {value: 1999, confidence: "high"},
          first_published_year_estimated: false,
          original_language: {value: "en", confidence: "high"},
          word_count: {value: 80_000, confidence: "medium"},
          page_range: {value: "300", confidence: "medium"},
          subtitle: {value: "A Subtitle", confidence: "high"},
          alternate_titles: {value: ["Fresh"], confidence: "medium"},
          origin_countries: {value: ["French"], confidence: "high"},
          book_type: {value: "fiction", confidence: "high"},
          series_name: {value: nil, confidence: "low"},
          series_number: {value: nil, confidence: "low"},
          description: {value: "A paragraph about a fresh book.", confidence: "high"}
        }.deep_merge(overrides)
      end

      def apply(overrides = {}, description: :default, citations: [])
        description = {text: "A paragraph about a fresh book.", review: {"spoilers" => false}, reason: nil} if description == :default
        ApplyBookFacts.call(book: @book, facts: facts(overrides), citations: citations, description: description)
      end

      test "fills every blank scalar and records filled" do
        result = apply

        assert result.success?
        @book.reload
        assert_equal 1999, @book.first_published_year
        assert_equal languages(:english), @book.original_language
        assert_equal 80_000, @book.word_count
        assert_equal "300", @book.page_range
        assert_equal "A Subtitle", @book.subtitle
        %w[first_published_year original_language word_count page_range subtitle].each do |name|
          assert_equal "filled", result.data[:facts][name]["reason"], name
          assert result.data[:facts][name]["applied"], name
          assert_includes result.data[:applied], name
        end
      end

      test "never overwrites a value that is already set" do
        @book.update!(first_published_year: 1950, word_count: 10, page_range: "12", subtitle: "Kept", original_language: languages(:french))

        result = apply

        @book.reload
        assert_equal [1950, 10, "12", "Kept", languages(:french)],
          [@book.first_published_year, @book.word_count, @book.page_range, @book.subtitle, @book.original_language]
        %w[first_published_year original_language word_count page_range subtitle].each do |name|
          assert_equal "already_set", result.data[:facts][name]["reason"], name
          refute result.data[:facts][name]["applied"], name
        end
      end

      test "a null value is recorded as null and not applied" do
        result = apply(first_published_year: {value: nil, confidence: "low"})

        assert_nil @book.reload.first_published_year
        assert_equal "null", result.data[:facts]["first_published_year"]["reason"]
      end

      test "carries each fact's confidence into the ledger" do
        result = apply

        assert_equal "medium", result.data[:facts]["word_count"]["confidence"]
        assert_equal "high", result.data[:facts]["first_published_year"]["confidence"]
      end

      test "original language matches by name when the value is not a code" do
        apply(original_language: {value: "english", confidence: "high"})

        assert_equal languages(:english), @book.reload.original_language
      end

      test "original language with no match is recorded as no_match and not applied" do
        result = apply(original_language: {value: "Englisch", confidence: "high"})

        assert_nil @book.reload.original_language
        assert_equal "no_match", result.data[:facts]["original_language"]["reason"]
        assert_equal "Englisch", result.data[:facts]["original_language"]["value"]
      end

      test "a zero or negative word count is invalid and not applied" do
        result = apply(word_count: {value: 0, confidence: "low"})

        assert_nil @book.reload.word_count
        assert_equal "invalid", result.data[:facts]["word_count"]["reason"]
      end

      test "a page range that is not a number or a range is invalid" do
        result = apply(page_range: {value: "about 300", confidence: "low"})

        assert_nil @book.reload.page_range
        assert_equal "invalid", result.data[:facts]["page_range"]["reason"]
      end

      test "a range page_range is accepted" do
        apply(page_range: {value: "250-350", confidence: "medium"})

        assert_equal "250-350", @book.reload.page_range
      end

      test "alternate titles are unioned, case-insensitively, excluding the title itself" do
        @book.update!(alternate_titles: ["Fresh"])

        result = apply(alternate_titles: {value: ["fresh", "A FRESH BOOK", "Frisch"], confidence: "medium"})

        assert_equal ["Fresh", "Frisch"], @book.reload.alternate_titles
        assert_equal "filled", result.data[:facts]["alternate_titles"]["reason"]
        assert_equal ["Frisch"], result.data[:facts]["alternate_titles"]["value"]
      end

      test "alternate titles with nothing new are already_set" do
        @book.update!(alternate_titles: ["Fresh"])

        result = apply

        assert_equal "already_set", result.data[:facts]["alternate_titles"]["reason"]
      end

      test "origin countries are added when the book has none" do
        result = apply

        assert_equal [books_countries(:french)], @book.reload.countries.to_a
        assert_equal "filled", result.data[:facts]["origin_countries"]["reason"]
        assert_equal [], result.data[:facts]["origin_countries"]["unmatched"]
      end

      test "origin countries are left alone when the book already has some" do
        @book.book_countries.create!(country: books_countries(:japanese))

        result = apply

        assert_equal [books_countries(:japanese)], @book.reload.countries.to_a
        assert_equal "already_set", result.data[:facts]["origin_countries"]["reason"]
      end

      test "origin countries with no match record the unmatched names and create nothing" do
        result = apply(origin_countries: {value: ["USA", "Martian"], confidence: "high"})

        assert_empty @book.reload.countries
        assert_equal "no_match", result.data[:facts]["origin_countries"]["reason"]
        assert_equal ["USA", "Martian"], result.data[:facts]["origin_countries"]["unmatched"]
      end

      test "book type and series are recorded but not applied" do
        result = apply(series_name: {value: "The Fresh Cycle", confidence: "medium"}, series_number: {value: 2, confidence: "medium"})

        %w[book_type series_name series_number].each do |name|
          assert_equal "not_applied_yet", result.data[:facts][name]["reason"], name
          refute result.data[:facts][name]["applied"], name
        end
        assert_equal "fiction", result.data[:facts]["book_type"]["value"]
        assert_equal "The Fresh Cycle", result.data[:facts]["series_name"]["value"]
        assert_empty @book.reload.series
      end

      test "first_published_year_estimated is recorded alongside the year" do
        result = apply(first_published_year_estimated: true)

        assert_equal true, result.data[:facts]["first_published_year_estimated"]["value"]
        assert_equal "not_applied_yet", result.data[:facts]["first_published_year_estimated"]["reason"]
      end

      test "writes the description as an ai_generated row with the first citation" do
        result = apply(citations: ["https://example.org/source", "https://example.org/other"])

        row = @book.descriptions.reload.find_by(source: :ai_generated)
        assert_equal "A paragraph about a fresh book.", row.content
        assert_equal "https://example.org/source", row.source_url
        assert_equal "filled", result.data[:facts]["description"]["reason"]
        assert_equal({"spoilers" => false}, result.data[:facts]["description"]["review"])
      end

      test "does not write a second ai_generated description" do
        @book.assign_description(source: :ai_generated, content: "Already here.").save!

        result = apply

        assert_equal 1, @book.descriptions.reload.where(source: :ai_generated).count
        assert_equal "Already here.", @book.descriptions.find_by(source: :ai_generated).content
        assert_equal "already_set", result.data[:facts]["description"]["reason"]
      end

      test "a manual description does not block the ai_generated row" do
        @book.assign_description(source: :manual, content: "Hand written.").save!

        apply

        assert_equal 2, @book.descriptions.reload.count
        assert_equal "Hand written.", @book.primary_description.content
      end

      test "a description with a rejection reason is recorded and not written" do
        result = apply(description: {text: "Bad -- text", review: {"spoilers" => true}, reason: "rejected"})

        assert_empty @book.descriptions.reload
        assert_equal "rejected", result.data[:facts]["description"]["reason"]
        refute result.data[:facts]["description"]["applied"]
        assert_equal({"spoilers" => true}, result.data[:facts]["description"]["review"])
      end

      test "no description at all is recorded as null" do
        result = apply({description: {value: nil, confidence: "low"}}, description: nil)

        assert_empty @book.descriptions.reload
        assert_equal "null", result.data[:facts]["description"]["reason"]
      end

      test "never touches the legacy description column" do
        apply

        assert_nil @book.reload.description
      end

      test "saves the book once with all fills" do
        ::Books::Book.any_instance.expects(:save!).once.returns(true)

        apply
      end

      test "applied lists only what changed" do
        @book.update!(first_published_year: 1950)

        result = apply

        refute_includes result.data[:applied], "first_published_year"
        assert_includes result.data[:applied], "word_count"
        assert_includes result.data[:applied], "description"
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web-app && bin/rails test test/lib/services/books/apply_book_facts_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::ApplyBookFacts`.

- [ ] **Step 3: Write the applier**

`web-app/app/lib/services/books/apply_book_facts.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # The only class that writes Books::Book columns from AI output. Policy:
    # fill a blank, union an array, never overwrite. Every fact gets a ledger
    # entry saying what happened and why, applied or not.
    #
    # Spec: docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §4-5.
    class ApplyBookFacts
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      PAGE_RANGE = /\A\d+(-\d+)?\z/
      RECORDED_ONLY = %w[book_type series_name series_number].freeze

      def self.call(book:, facts:, citations: [], description: nil)
        new(book: book, facts: facts, citations: citations, description: description).call
      end

      def initialize(book:, facts:, citations:, description:)
        @book = book
        @facts = facts.deep_symbolize_keys
        @citations = Array(citations)
        @description = description
        @ledger = {}
        @applied = []
      end

      def call
        apply_first_published_year
        apply_original_language
        apply_word_count
        apply_page_range
        apply_subtitle
        apply_alternate_titles
        apply_origin_countries
        record_only_facts
        apply_description

        book.save!
        Result.new(success?: true, data: {facts: ledger, applied: applied}, errors: [])
      end

      private

      attr_reader :book, :facts, :citations, :description, :ledger, :applied

      def fact(name) = facts.fetch(name, {}) || {}

      def record(name, fact, applied:, reason:, value: fact[:value], **extra)
        ledger[name.to_s] = {"value" => value, "confidence" => fact[:confidence], "applied" => applied, "reason" => reason}.merge(extra.stringify_keys)
        self.applied << name.to_s if applied
      end

      def fill_scalar(name, column:, present: -> { book.public_send(column).present? }, valid: ->(_) { true }, cast: ->(v) { v })
        f = fact(name)
        value = f[:value]
        if value.nil? || (value.respond_to?(:empty?) && value.empty?)
          record(name, f, applied: false, reason: "null")
        elsif !valid.call(value)
          record(name, f, applied: false, reason: "invalid")
        elsif present.call
          record(name, f, applied: false, reason: "already_set")
        else
          book.public_send(:"#{column}=", cast.call(value))
          record(name, f, applied: true, reason: "filled")
        end
      end

      def apply_first_published_year
        fill_scalar(:first_published_year, column: :first_published_year, valid: ->(v) { v.is_a?(Integer) }, cast: ->(v) { v })
        ledger["first_published_year_estimated"] = {
          "value" => facts[:first_published_year_estimated],
          "confidence" => fact(:first_published_year)[:confidence],
          "applied" => false,
          "reason" => "not_applied_yet"
        }
      end

      def apply_original_language
        f = fact(:original_language)
        value = f[:value].to_s.strip
        return record(:original_language, f, applied: false, reason: "null") if value.blank?
        return record(:original_language, f, applied: false, reason: "already_set") if book.original_language_id.present?

        language = find_language(value)
        return record(:original_language, f, applied: false, reason: "no_match") if language.nil?

        book.original_language = language
        record(:original_language, f, applied: true, reason: "filled", matched: language.name)
      end

      def find_language(value)
        downcased = value.downcase
        (Language.find_by(iso_639_1: downcased) if downcased.length == 2) ||
          Language.where("lower(name) = ?", downcased).first
      end

      def apply_word_count
        fill_scalar(:word_count, column: :word_count, valid: ->(v) { v.is_a?(Integer) && v.positive? })
      end

      def apply_page_range
        fill_scalar(:page_range, column: :page_range, valid: ->(v) { v.to_s.match?(PAGE_RANGE) }, cast: ->(v) { v.to_s })
      end

      def apply_subtitle
        fill_scalar(:subtitle, column: :subtitle, cast: ->(v) { v.to_s.strip })
      end

      def apply_alternate_titles
        f = fact(:alternate_titles)
        incoming = Array(f[:value]).map { |t| t.to_s.strip }.reject(&:blank?)
        return record(:alternate_titles, f, applied: false, reason: "null", value: []) if incoming.empty?

        existing = Array(book.alternate_titles)
        taken = (existing + [book.title]).map(&:downcase)
        new_titles = incoming.reject { |t| taken.include?(t.downcase) }.uniq(&:downcase)
        return record(:alternate_titles, f, applied: false, reason: "already_set", value: []) if new_titles.empty?

        book.alternate_titles = existing + new_titles
        record(:alternate_titles, f, applied: true, reason: "filled", value: new_titles)
      end

      def apply_origin_countries
        f = fact(:origin_countries)
        names = Array(f[:value]).map { |n| n.to_s.strip }.reject(&:blank?)
        return record(:origin_countries, f, applied: false, reason: "null", value: [], unmatched: []) if names.empty?
        return record(:origin_countries, f, applied: false, reason: "already_set", unmatched: []) if book.book_countries.exists?

        matched, unmatched = names.partition { |name| find_country(name) }
        matched.each { |name| book.book_countries.build(country: find_country(name)) }

        if matched.any?
          record(:origin_countries, f, applied: true, reason: "filled", value: matched, unmatched: unmatched)
        else
          record(:origin_countries, f, applied: false, reason: "no_match", unmatched: unmatched)
        end
      end

      def find_country(name)
        @countries ||= {}
        @countries[name.downcase] ||= ::Books::Country.where("lower(name) = ?", name.downcase).first
      end

      def record_only_facts
        RECORDED_ONLY.each do |name|
          f = fact(name.to_sym)
          record(name, f, applied: false, reason: f[:value].nil? ? "null" : "not_applied_yet")
        end
      end

      def apply_description
        f = fact(:description)
        if description.nil?
          return record(:description, f, applied: false, reason: "null")
        end

        review = description[:review]
        if description[:reason].present?
          return record(:description, f, applied: false, reason: description[:reason], value: description[:text], review: review)
        end
        if book.descriptions.any? { |d| d.source == "ai_generated" }
          return record(:description, f, applied: false, reason: "already_set", value: description[:text], review: review)
        end

        book.assign_description(source: :ai_generated, content: description[:text], source_url: citations.first)
        record(:description, f, applied: true, reason: "filled", value: description[:text], review: review)
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests and lint**

Run: `cd web-app && bin/rails test test/lib/services/books/apply_book_facts_test.rb && bundle exec standardrb app/lib/services/books/apply_book_facts.rb test/lib/services/books/apply_book_facts_test.rb`
Expected: 24 runs, 0 failures. If the `saves the book once` test fails because `assign_description`'s autosave triggers a nested save, that is not a second `save!` on the book; investigate before changing the assertion.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books/apply_book_facts.rb web-app/test/lib/services/books/apply_book_facts_test.rb
git commit -m "Add ApplyBookFacts: fill-blanks write policy for AI book facts

One class writes Books::Book from AI output. Fills blanks, unions
alternate titles, adds countries only when there are none, writes the
description as an ai_generated row, and records every fact's outcome."
```

---

### Task 6: `DescriptionCheck` and `DescriptionReviewTask`

**Files:**
- Create: `web-app/app/lib/services/books/description_check.rb`
- Create: `web-app/app/lib/services/ai/tasks/books/description_review_task.rb`
- Create: `web-app/test/lib/services/books/description_check_test.rb`
- Create: `web-app/test/lib/services/ai/tasks/books/description_review_task_test.rb`

**Interfaces:**
- Produces: `Services::Books::DescriptionCheck.call(text, book:) -> Result` with `data: {text: String}` (citations stripped) and `errors: Array<String>` from `em_dash`, `double_hyphen`, `url`, `markdown_link`, `names_title`, `too_short`, `too_long`. `success?` is `errors.empty?`.
- Produces: `Services::Ai::Tasks::Books::DescriptionReviewTask.new(parent: book, description: String)`; `#call` returns `Result` with `data` `{spoilers: bool, spoiler_notes: String|nil, style_violations: Array<String>, rewritten: String|nil}`.

- [ ] **Step 1: Write the failing check tests**

`web-app/test/lib/services/books/description_check_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    class DescriptionCheckTest < ActiveSupport::TestCase
      CLEAN = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip

      def setup
        @book = books_books(:war_and_peace)
      end

      test "passes clean text unchanged" do
        result = DescriptionCheck.call(CLEAN, book: @book)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
        assert_equal [], result.errors
      end

      test "strips markdown citations before checking and keeps the rest" do
        text = "#{CLEAN} ([penguinrandomhouse.com](https://www.penguinrandomhouse.com/x?utm_source=openai))"

        result = DescriptionCheck.call(text, book: @book)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
      end

      test "stripping is idempotent" do
        text = "#{CLEAN} ([a](https://a.example))"
        once = DescriptionCheck.call(text, book: @book).data[:text]

        assert_equal once, DescriptionCheck.call(once, book: @book).data[:text]
      end

      test "flags em dashes and double hyphens" do
        assert_includes DescriptionCheck.call("#{CLEAN} A man — a widow.", book: @book).errors, "em_dash"
        assert_includes DescriptionCheck.call("#{CLEAN} A man -- a widow.", book: @book).errors, "double_hyphen"
      end

      test "flags a bare url and a markdown link that survived stripping" do
        assert_includes DescriptionCheck.call("#{CLEAN} See https://example.org.", book: @book).errors, "url"
        assert_includes DescriptionCheck.call("#{CLEAN} See [here](x).", book: @book).errors, "markdown_link"
      end

      test "flags the book's title as a whole phrase, case-insensitively" do
        result = DescriptionCheck.call("#{CLEAN} It is war AND peace in one.", book: @book)

        assert_includes result.errors, "names_title"
      end

      test "does not flag the title inside another word" do
        book = ::Books::Book.new(title: "It")

        assert DescriptionCheck.call(CLEAN, book: book).success?
      end

      test "flags fewer than 40 or more than 140 words" do
        assert_includes DescriptionCheck.call("Too short.", book: @book).errors, "too_short"
        assert_includes DescriptionCheck.call(("word " * 141).strip, book: @book).errors, "too_long"
      end

      test "reports every error at once" do
        result = DescriptionCheck.call("Short — https://x.example", book: @book)

        assert_equal %w[em_dash url too_short], result.errors
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web-app && bin/rails test test/lib/services/books/description_check_test.rb`
Expected: FAIL with `NameError`.

- [ ] **Step 3: Write the check**

`web-app/app/lib/services/books/description_check.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Deterministic guard on an AI description before it is written. The
    # prompt forbids all of this and the review task looks for it; this is
    # the part a regex can prove. Word bounds are looser than the prompt's
    # 60 to 110 on purpose: they catch runaways, not the target.
    class DescriptionCheck
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # "([label](https://url))", the shape the model pastes in despite the
      # rules. The URLs are already in the run's citations.
      MARKDOWN_CITATION = /\s*\(\[[^\]]*\]\([^)]*\)\)/
      MIN_WORDS = 40
      MAX_WORDS = 140

      def self.call(text, book:)
        cleaned = text.to_s.gsub(MARKDOWN_CITATION, "").strip
        errors = []
        errors << "em_dash" if cleaned.include?("—")
        errors << "double_hyphen" if cleaned.include?("--")
        errors << "url" if cleaned.match?(%r{https?://})
        errors << "markdown_link" if cleaned.include?("](")
        errors << "names_title" if names_title?(cleaned, book.title)
        words = cleaned.split(/\s+/).size
        errors << "too_short" if words < MIN_WORDS
        errors << "too_long" if words > MAX_WORDS

        Result.new(success?: errors.empty?, data: {text: cleaned}, errors: errors)
      end

      def self.names_title?(text, title)
        return false if title.blank?

        text.match?(/(?<![[:alnum:]])#{Regexp.escape(title)}(?![[:alnum:]])/i)
      end
      private_class_method :names_title?
    end
  end
end
```

- [ ] **Step 4: Run the check tests**

Run: `cd web-app && bin/rails test test/lib/services/books/description_check_test.rb`
Expected: 9 runs, 0 failures.

- [ ] **Step 5: Write the failing review task test**

`web-app/test/lib/services/ai/tasks/books/description_review_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class DescriptionReviewTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @task = DescriptionReviewTask.new(parent: @book, description: "A paragraph — with a dash.")
          end

          test "runs on the fast role with openai and json mode" do
            assert_equal :fast, @task.send(:task_role)
            assert_equal "gpt-6-luna", @task.instance_variable_get(:@model)
            assert_equal :openai, @task.send(:provider).provider_key
            assert_equal({type: "json_object"}, @task.send(:response_format))
            assert_equal DescriptionReviewTask::ResponseSchema, @task.send(:response_schema)
          end

          test "user prompt carries the description, the title and the authors so it can spot them" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "A paragraph — with a dash."
            assert_includes prompt, "War and Peace"
            assert_includes prompt, "Leo Tolstoy"
          end

          test "system message lists the violation codes" do
            message = @task.send(:system_message)

            DescriptionReviewTask::VIOLATIONS.each { |code| assert_includes message, code }
            assert_includes message, "spoiler"
          end

          test "process_and_persist returns the parsed review and writes nothing" do
            @task.stubs(:chat).returns(ai_chats(:general_chat))
            parsed = {spoilers: false, spoiler_notes: nil, style_violations: ["em_dash"], rewritten: "A paragraph, with a comma."}
            before = @book.descriptions.count

            result = @task.send(:process_and_persist, {parsed: parsed})

            assert result.success?
            assert_equal parsed, result.data
            assert_equal before, @book.descriptions.reload.count
          end
        end
      end
    end
  end
end
```

Run: `cd web-app && bin/rails test test/lib/services/ai/tasks/books/description_review_task_test.rb`
Expected: FAIL with `NameError`.

- [ ] **Step 6: Write the review task**

`web-app/app/lib/services/ai/tasks/books/description_review_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      module Books
        # Second opinion on a generated description, on the cheap role. Style
        # is also checked in code (Services::Books::DescriptionCheck); spoilers
        # can only be checked by a reader, so this is the reader.
        class DescriptionReviewTask < BaseTask
          VIOLATIONS = %w[em_dash semicolon names_title names_author marketing meta_narration banned_word not_but triad too_long too_short citation].freeze

          def initialize(parent:, description:, provider: nil, model: nil)
            @description = description.to_s
            super(parent: parent, provider: provider, model: model)
          end

          private

          attr_reader :description

          def task_provider = :openai

          def task_role = :fast

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM_MESSAGE
              You review one short book description against these rules and fix it if needed.

              Spoilers: the description may describe the premise, the setting, and the situation the book opens on. It must not reveal twists, deaths, endings, or how the central question resolves. For nonfiction it must not give away the conclusions. Set "spoilers" to true if it does, and say what in "spoiler_notes".

              Style violations, reported as codes in "style_violations" (empty list when clean):
              - em_dash: an em dash (—) or double hyphen (--)
              - semicolon: a semicolon
              - names_title: names the book's title
              - names_author: names the author
              - marketing: praise or sales language such as acclaimed, bestselling, masterpiece, unforgettable, must-read, awards, sales figures
              - meta_narration: "This novel", "This book", "Readers will", or similar
              - banned_word: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, "explores themes of"
              - not_but: a "not X but Y" or "isn't about X, it's about Y" construction
              - triad: an ornamental run of three adjectives or phrases
              - too_long: more than 110 words
              - too_short: fewer than 60 words
              - citation: a URL, bracketed reference, footnote, or citation

              If "spoilers" is true or "style_violations" is not empty, put a corrected version in "rewritten": one paragraph, 60 to 110 words, plain words, varied sentence length, no title or author name, same facts, nothing invented, spoilers removed. Otherwise set "rewritten" to null.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def user_prompt
            <<~PROMPT
              Book title: #{parent.title}
              Author(s): #{parent.authors.map(&:name).join(", ")}

              Description to review:
              #{description}
            PROMPT
          end

          def process_and_persist(provider_response)
            Services::Ai::Result.new(success: true, data: provider_response[:parsed], ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :spoilers, OpenAI::Boolean, doc: "true if the description reveals more than the premise"
            required :spoiler_notes, String, nil?: true, doc: "What was revealed, when spoilers is true"
            required :style_violations, OpenAI::ArrayOf[String], doc: "Violation codes from the list, empty when clean"
            required :rewritten, String, nil?: true, doc: "Corrected description, or null when nothing needed changing"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 7: Run both test files and lint**

Run: `cd web-app && bin/rails test test/lib/services/books/description_check_test.rb test/lib/services/ai/tasks/books/description_review_task_test.rb && bundle exec standardrb app/lib/services/books/description_check.rb app/lib/services/ai/tasks/books/description_review_task.rb test/lib/services/books/description_check_test.rb test/lib/services/ai/tasks/books/description_review_task_test.rb`
Expected: 13 runs, 0 failures; no lint output.

- [ ] **Step 8: Commit**

```bash
git add web-app/app/lib/services/books/description_check.rb web-app/app/lib/services/ai/tasks/books/description_review_task.rb web-app/test/lib/services/books/description_check_test.rb web-app/test/lib/services/ai/tasks/books/description_review_task_test.rb
git commit -m "Add the description review task and deterministic check

The fast-role reviewer flags spoilers and style codes and rewrites;
DescriptionCheck strips pasted citations and rejects dashes, URLs, the
title, and runaway lengths."
```

---

### Task 7: `Services::Books::EnrichBook` runner

**Files:**
- Create: `web-app/app/lib/services/books/enrich_book.rb`
- Create: `web-app/test/lib/services/books/enrich_book_test.rb`

**Interfaces:**
- Consumes: `BookFactsTask.new(parent:, mode:, author_names:)` (Task 4), `DescriptionReviewTask.new(parent:, description:)` (Task 6), `DescriptionCheck.call` (Task 6), `ApplyBookFacts.call` (Task 5), `Enrichment` (Task 3), `config.x.ai.knowledge_cutoff_year` and `.research_daily_cap` (Task 1).
- Produces: `Services::Books::EnrichBook.call(book:, force_research: false, author_names: nil) -> Result` with `data: {enrichments: Array<Enrichment>}`; `success?` false when any run failed, `errors` carrying the messages. `KIND = "books.book_facts"`.

- [ ] **Step 1: Write the failing runner tests**

`web-app/test/lib/services/books/enrich_book_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    class EnrichBookTest < ActiveSupport::TestCase
      def setup
        @book = ::Books::Book.create!(title: "A Fresh Book")
        @book.book_authors.create!(author: books_authors(:tolstoy), position: 1)
        @chat = AiChat.create!(parent: @book, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
        # Every run gets a clean description review unless a test says otherwise.
        stub_review(spoilers: false, style_violations: [], rewritten: nil)
      end

      CLEAN_DESCRIPTION = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip

      def facts(overrides = {})
        {
          recognized: true,
          confidence: "high",
          first_published_year: {value: 1999, confidence: "high"},
          first_published_year_estimated: false,
          original_language: {value: "en", confidence: "high"},
          word_count: {value: nil, confidence: "low"},
          page_range: {value: nil, confidence: "low"},
          subtitle: {value: nil, confidence: "low"},
          alternate_titles: {value: [], confidence: "low"},
          origin_countries: {value: [], confidence: "low"},
          book_type: {value: "fiction", confidence: "high"},
          series_name: {value: nil, confidence: "low"},
          series_number: {value: nil, confidence: "low"},
          description: {value: CLEAN_DESCRIPTION, confidence: "high"}
        }.deep_merge(overrides)
      end

      def success_result(facts_hash, citations: [])
        Services::Ai::Result.new(success: true, data: {facts: facts_hash, citations: citations}, ai_chat: @chat)
      end

      def failure_result(message)
        Services::Ai::Result.new(success: false, error: message)
      end

      # Expects BookFactsTask to be built once per listed mode, in order, and
      # returns the given results.
      def expect_facts_runs(*runs)
        runs.each do |mode, result|
          task = mock
          task.stubs(:call).returns(result)
          Services::Ai::Tasks::Books::BookFactsTask.expects(:new)
            .with { |args| args[:parent] == @book && args[:mode] == mode }
            .returns(task)
        end
      end

      def stub_review(spoilers:, style_violations:, rewritten:, success: true)
        review = mock
        result = if success
          Services::Ai::Result.new(success: true, data: {spoilers: spoilers, spoiler_notes: nil, style_violations: style_violations, rewritten: rewritten}, ai_chat: @chat)
        else
          Services::Ai::Result.new(success: false, error: "review down")
        end
        review.stubs(:call).returns(result)
        Services::Ai::Tasks::Books::DescriptionReviewTask.stubs(:new).returns(review)
      end

      test "a recognized high-confidence knowledge run applies and writes one applied row" do
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert result.success?
        rows = result.data[:enrichments]
        assert_equal 1, rows.size
        row = rows.first
        assert row.knowledge?
        assert row.applied?
        assert_equal true, row.recognized
        assert row.confidence_high?
        assert_equal "books.book_facts", row.kind
        assert_equal @chat, row.ai_chat
        assert_equal "gpt-6-sol", row.model
        assert_equal "openai", row.provider
        assert_equal 1999, @book.reload.first_published_year
        assert_equal CLEAN_DESCRIPTION, @book.primary_description.content
        assert row.facts["description"]["applied"]
      end

      test "an unrecognized knowledge run applies nothing and falls back to research" do
        research_facts = facts(first_published_year: {value: 2001, confidence: "medium"}, confidence: "medium")
        expect_facts_runs(
          [:knowledge, success_result(facts(recognized: false, confidence: "low", first_published_year: {value: 1999, confidence: "low"}))],
          [:research, success_result(research_facts, citations: ["https://example.org/src"])]
        )

        result = EnrichBook.call(book: @book)

        assert result.success?
        knowledge, research = result.data[:enrichments]
        assert knowledge.unrecognized?
        assert_equal "unrecognized", knowledge.facts["first_published_year"]["reason"]
        refute knowledge.facts["first_published_year"]["applied"]
        assert research.research?
        assert research.applied?
        assert_equal ["https://example.org/src"], research.citations
        assert_equal 2001, @book.reload.first_published_year
        assert_equal "https://example.org/src", @book.descriptions.find_by(source: :ai_generated).source_url
      end

      test "a recognized but low-confidence run falls back to research" do
        expect_facts_runs(
          [:knowledge, success_result(facts(confidence: "low"))],
          [:research, success_result(facts(confidence: "high"))]
        )

        result = EnrichBook.call(book: @book)

        assert_equal %w[knowledge research], result.data[:enrichments].map(&:mode)
      end

      test "medium confidence does not trigger research" do
        expect_facts_runs([:knowledge, success_result(facts(confidence: "medium"))])

        result = EnrichBook.call(book: @book)

        assert_equal %w[knowledge], result.data[:enrichments].map(&:mode)
      end

      test "a book published at or after the cutoff skips the knowledge call" do
        @book.update!(first_published_year: Rails.application.config.x.ai.knowledge_cutoff_year)
        expect_facts_runs([:research, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert_equal %w[research], result.data[:enrichments].map(&:mode)
      end

      test "force_research goes straight to research" do
        expect_facts_runs([:research, success_result(facts)])

        EnrichBook.call(book: @book, force_research: true)
      end

      test "an exhausted research budget writes a skipped row instead of researching" do
        # A cap of zero is exhausted before the first research run.
        Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
        expect_facts_runs([:knowledge, success_result(facts(recognized: false, confidence: "low"))])

        result = EnrichBook.call(book: @book)

        assert result.success?
        knowledge, skipped = result.data[:enrichments]
        assert knowledge.unrecognized?
        assert skipped.skipped?
        assert skipped.research?
        assert_equal "budget_exhausted", skipped.reason
        assert_nil skipped.ai_chat
      end

      test "force_research ignores the budget" do
        Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
        expect_facts_runs([:research, success_result(facts)])

        result = EnrichBook.call(book: @book, force_research: true)

        assert_equal %w[research], result.data[:enrichments].map(&:mode)
      end

      test "a book with no title or author names is skipped as missing_inputs" do
        bare = ::Books::Book.create!(title: "Bare")
        Services::Ai::Tasks::Books::BookFactsTask.expects(:new).never

        result = EnrichBook.call(book: bare)

        assert result.success?
        row = result.data[:enrichments].first
        assert row.skipped?
        assert_equal "missing_inputs", row.reason
      end

      test "passed author names satisfy the inputs check and reach the task" do
        bare = ::Books::Book.create!(title: "Bare")
        task = mock
        task.stubs(:call).returns(success_result(facts))
        Services::Ai::Tasks::Books::BookFactsTask.expects(:new)
          .with { |args| args[:parent] == bare && args[:author_names] == ["Someone"] }
          .returns(task)

        result = EnrichBook.call(book: bare, author_names: ["Someone"])

        assert result.data[:enrichments].first.applied?
      end

      test "a task failure writes a failed row and returns failure" do
        expect_facts_runs([:knowledge, failure_result("OpenAI timeout")])

        result = EnrichBook.call(book: @book)

        refute result.success?
        assert_equal ["OpenAI timeout"], result.errors
        row = result.data[:enrichments].first
        assert row.failed?
        assert_equal "OpenAI timeout", row.error
        assert_equal "gpt-6-sol", row.model
        assert_nil @book.reload.first_published_year
      end

      test "a research failure after a good knowledge run keeps the knowledge row and reports failure" do
        expect_facts_runs(
          [:knowledge, success_result(facts(recognized: false, confidence: "low"))],
          [:research, failure_result("search down")]
        )

        result = EnrichBook.call(book: @book)

        refute result.success?
        assert_equal %w[unrecognized failed], result.data[:enrichments].map(&:outcome)
        assert_equal "gpt-6-astra", result.data[:enrichments].last.model
      end

      test "the reviewer's rewrite is what gets written, and the ledger says so" do
        rewritten = ("A young man in a small town cares for a widow who is losing her memory. " * 4).strip
        stub_review(spoilers: true, style_violations: ["em_dash"], rewritten: rewritten)
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert_equal rewritten, @book.reload.primary_description.content
        review = result.data[:enrichments].first.facts["description"]["review"]
        assert_equal true, review["spoilers"]
        assert_equal ["em_dash"], review["style_violations"]
        assert_equal true, review["rewritten"]
        assert_equal [], review["check_errors"]
      end

      test "a description that fails the deterministic check is rejected, other facts still apply" do
        expect_facts_runs([:knowledge, success_result(facts(description: {value: "Short — bad.", confidence: "high"}))])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert row.applied?
        assert_equal "rejected", row.facts["description"]["reason"]
        assert_includes row.facts["description"]["review"]["check_errors"], "em_dash"
        assert_empty @book.reload.descriptions
        assert_equal 1999, @book.first_published_year
      end

      test "a failed review records review_failed and does not write the description" do
        stub_review(spoilers: false, style_violations: [], rewritten: nil, success: false)
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert_equal "review_failed", row.facts["description"]["reason"]
        assert_empty @book.reload.descriptions
        assert row.applied?
      end

      test "a null description skips the review entirely" do
        Services::Ai::Tasks::Books::DescriptionReviewTask.expects(:new).never
        expect_facts_runs([:knowledge, success_result(facts(description: {value: nil, confidence: "low"}))])

        result = EnrichBook.call(book: @book)

        assert_equal "null", result.data[:enrichments].first.facts["description"]["reason"]
      end

      test "nothing_to_apply when every fact was already set" do
        @book.update!(first_published_year: 1950, original_language: languages(:english))
        @book.assign_description(source: :ai_generated, content: "Here.").save!
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert result.data[:enrichments].first.nothing_to_apply?
      end

      test "an unknown confidence string is stored as nil and does not break the run" do
        expect_facts_runs([:knowledge, success_result(facts(confidence: "certain"))])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert_nil row.confidence
        assert row.applied?
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web-app && bin/rails test test/lib/services/books/enrich_book_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::EnrichBook`.

- [ ] **Step 3: Write the runner**

`web-app/app/lib/services/books/enrich_book.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Runs the book facts task, reviews the description, applies the facts,
    # and decides whether a web-search run is warranted. Writes exactly one
    # Enrichment row per run, including skips and failures.
    #
    # Spec: docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §6.
    class EnrichBook
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      KIND = "books.book_facts"

      def self.call(book:, force_research: false, author_names: nil)
        new(book: book, force_research: force_research, author_names: author_names).call
      end

      def initialize(book:, force_research:, author_names:)
        @book = book
        @force_research = force_research
        @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
        @rows = []
      end

      def call
        unless inputs_present?
          rows << skip("missing_inputs", mode: :knowledge)
          return result
        end

        first_mode = (force_research || past_cutoff?) ? :research : :knowledge
        rows << run(first_mode)
        return result if rows.last.failed?

        if first_mode == :knowledge && needs_research?(rows.last)
          if budget_exhausted? && !force_research
            rows << skip("budget_exhausted", mode: :research)
          else
            rows << run(:research)
          end
        end

        result
      end

      private

      attr_reader :book, :force_research, :rows

      def author_names
        @author_names.presence || book.authors.map(&:name)
      end

      def inputs_present?
        book.title.present? && author_names.any?
      end

      def past_cutoff?
        year = book.first_published_year
        year.present? && year >= Rails.application.config.x.ai.knowledge_cutoff_year
      end

      def needs_research?(row)
        row.recognized == false || (row.recognized && row.confidence_low?)
      end

      def budget_exhausted?
        Enrichment.research.today.count >= Rails.application.config.x.ai.research_daily_cap
      end

      def run(mode)
        task_result = Services::Ai::Tasks::Books::BookFactsTask.new(parent: book, mode: mode, author_names: author_names).call
        return failed_row(mode, task_result) unless task_result.success?

        facts = task_result.data[:facts].deep_symbolize_keys
        citations = Array(task_result.data[:citations])
        chat = task_result.ai_chat

        if facts[:recognized] == false
          return book.enrichments.create!(
            row_attributes(mode, chat).merge(
              outcome: :unrecognized,
              recognized: false,
              confidence: confidence_for(facts[:confidence]),
              facts: unapplied_facts(facts),
              citations: citations
            )
          )
        end

        description = review_description(facts.dig(:description, :value))
        applied = ApplyBookFacts.call(book: book, facts: facts, citations: citations, description: description)

        book.enrichments.create!(
          row_attributes(mode, chat).merge(
            outcome: applied.data[:applied].any? ? :applied : :nothing_to_apply,
            recognized: facts[:recognized],
            confidence: confidence_for(facts[:confidence]),
            facts: applied.data[:facts],
            citations: citations
          )
        )
      end

      def failed_row(mode, task_result)
        role = Services::Ai::Roles.resolve(mode == :research ? :research : :standard)
        book.enrichments.create!(
          kind: KIND,
          mode: mode,
          outcome: :failed,
          error: task_result.error,
          provider: role.provider.to_s,
          model: role.model,
          ai_chat: task_result.ai_chat
        )
      end

      def row_attributes(mode, chat)
        {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
      end

      def skip(reason, mode:)
        book.enrichments.create!(kind: KIND, mode: mode, outcome: :skipped, reason: reason)
      end

      def confidence_for(value)
        Enrichment.confidences.key?(value.to_s) ? value.to_s : nil
      end

      # A model that does not know the book is guessing at whatever it did
      # return, so nothing is applied; the facts are still kept for the record.
      def unapplied_facts(facts)
        facts.except(:recognized, :confidence).to_h do |name, fact|
          entry = fact.is_a?(Hash) ? {"value" => fact[:value], "confidence" => fact[:confidence]} : {"value" => fact, "confidence" => nil}
          [name.to_s, entry.merge("applied" => false, "reason" => "unrecognized")]
        end
      end

      # nil when there is no description to review. Otherwise
      # {text:, review:, reason:}; a reason means "do not write".
      def review_description(text)
        return nil if text.blank?

        review = Services::Ai::Tasks::Books::DescriptionReviewTask.new(parent: book, description: text).call
        return {text: text, review: nil, reason: "review_failed"} unless review.success?

        data = review.data.deep_symbolize_keys
        reviewed = data[:rewritten].presence || text
        check = DescriptionCheck.call(reviewed, book: book)

        {
          text: check.data[:text],
          review: {
            "spoilers" => data[:spoilers],
            "spoiler_notes" => data[:spoiler_notes],
            "style_violations" => Array(data[:style_violations]),
            "rewritten" => data[:rewritten].present?,
            "check_errors" => check.errors
          },
          reason: check.success? ? nil : "rejected"
        }
      end

      def result
        failures = rows.select(&:failed?)
        Result.new(success?: failures.empty?, data: {enrichments: rows}, errors: failures.map(&:error))
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests and lint**

Run: `cd web-app && bin/rails test test/lib/services/books/enrich_book_test.rb && bundle exec standardrb app/lib/services/books/enrich_book.rb test/lib/services/books/enrich_book_test.rb`
Expected: 18 runs, 0 failures; no lint output.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books/enrich_book.rb web-app/test/lib/services/books/enrich_book_test.rb
git commit -m "Add EnrichBook: knowledge run, review, apply, research fallback

Research runs when the model did not recognize the book, was low
confidence, or the book postdates the knowledge cutoff, under a daily
cap the admin force option ignores. One ledger row per run."
```

---

### Task 8: `Books::EnrichBookJob`

**Files:**
- Create (generator): `web-app/app/sidekiq/books/enrich_book_job.rb`, `web-app/test/sidekiq/books/enrich_book_job_test.rb`

**Interfaces:**
- Consumes: `Services::Books::EnrichBook.call(book:, force_research:, author_names:)` (Task 7).
- Produces: `Books::EnrichBookJob.perform_async(book_id, force_research = false, author_names = [])`, queue `default`, `retry: 3`.

- [ ] **Step 1: Generate the job**

Run: `cd web-app && bin/rails generate sidekiq:job books/enrich_book`
Expected: `app/sidekiq/books/enrich_book_job.rb` and `test/sidekiq/books/enrich_book_job_test.rb`.

- [ ] **Step 2: Write the failing test**

Replace `web-app/test/sidekiq/books/enrich_book_job_test.rb`:

```ruby
require "test_helper"

class Books::EnrichBookJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
    @job = Books::EnrichBookJob.new
  end

  test "runs on the default queue with three retries" do
    assert_equal "default", Books::EnrichBookJob.get_sidekiq_options["queue"].to_s
    assert_equal 3, Books::EnrichBookJob.get_sidekiq_options["retry"]
  end

  test "calls the runner with the book and defaults" do
    Services::Books::EnrichBook.expects(:call)
      .with(book: @book, force_research: false, author_names: [])
      .returns(Services::Books::EnrichBook::Result.new(success?: true, data: {enrichments: []}, errors: []))

    @job.perform(@book.id)
  end

  test "passes force_research and author names through" do
    Services::Books::EnrichBook.expects(:call)
      .with(book: @book, force_research: true, author_names: ["Leo Tolstoy"])
      .returns(Services::Books::EnrichBook::Result.new(success?: true, data: {enrichments: []}, errors: []))

    @job.perform(@book.id, true, ["Leo Tolstoy"])
  end

  test "re-raises on a failed result so Sidekiq retries" do
    Services::Books::EnrichBook.stubs(:call)
      .returns(Services::Books::EnrichBook::Result.new(success?: false, data: {enrichments: []}, errors: ["OpenAI timeout"]))

    error = assert_raises(StandardError) { @job.perform(@book.id) }
    assert_includes error.message, "OpenAI timeout"
    assert_includes error.message, @book.id.to_s
  end

  test "returns quietly when the book no longer exists" do
    Services::Books::EnrichBook.expects(:call).never

    assert_nothing_raised { @job.perform(-1) }
  end
end
```

Run: `cd web-app && bin/rails test test/sidekiq/books/enrich_book_job_test.rb`
Expected: FAIL (generated job has no body).

- [ ] **Step 3: Write the job**

`web-app/app/sidekiq/books/enrich_book_job.rb`:

```ruby
# frozen_string_literal: true

# One book through Services::Books::EnrichBook. Fill-blanks makes a retry,
# a re-run, and two concurrent runs on one book all safe, so this stays on
# the default queue rather than serial.
class Books::EnrichBookJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  # author_names lets the importer enrich a brand-new book before it has
  # book_authors rows; the runner falls back to book.authors when empty.
  def perform(book_id, force_research = false, author_names = [])
    book = ::Books::Book.find_by(id: book_id)
    # Deleted between enqueue and run: nothing to do, not worth three retries.
    return if book.nil?

    result = ::Services::Books::EnrichBook.call(
      book: book,
      force_research: force_research,
      author_names: Array(author_names)
    )
    return if result.success?

    raise StandardError, "Enrichment failed for book #{book_id}: #{result.errors.join("; ")}"
  end
end
```

- [ ] **Step 4: Run, lint, commit**

Run: `cd web-app && bin/rails test test/sidekiq/books/enrich_book_job_test.rb && bundle exec standardrb app/sidekiq/books/enrich_book_job.rb test/sidekiq/books/enrich_book_job_test.rb`
Expected: 5 runs, 0 failures.

```bash
git add web-app/app/sidekiq/books/enrich_book_job.rb web-app/test/sidekiq/books/enrich_book_job_test.rb
git commit -m "Add Books::EnrichBookJob"
```

---

### Task 9: Importer provider `AiEnrichment`

**Files:**
- Create: `web-app/app/lib/data_importers/books/book/providers/ai_enrichment.rb`
- Create: `web-app/test/lib/data_importers/books/book/providers/ai_enrichment_test.rb`
- Modify: `web-app/app/lib/data_importers/books/book/importer.rb:34-36`
- Modify: `web-app/test/lib/data_importers/books/book/importer_test.rb` (setup stub, provider order test)

**Interfaces:**
- Consumes: `Books::EnrichBookJob.perform_async(book_id, force_research, author_names)` (Task 8); `DataImporters::ProviderBase#success_result/failure_result`; `ImportQuery#author_names`.
- Produces: `DataImporters::Books::Book::Providers::AiEnrichment#populate(book, query:, match: nil)` returning `ProviderResult` with `data_populated: [:ai_enrichment_queued]`.

- [ ] **Step 1: Write the failing provider test**

`web-app/test/lib/data_importers/books/book/providers/ai_enrichment_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AiEnrichmentTest < ActiveSupport::TestCase
          def setup
            @provider = AiEnrichment.new
            @book = books_books(:war_and_peace)
            @query = ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"])
          end

          test "queues the job with the book's own authors and reports success" do
            ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false, ["Leo Tolstoy"])

            result = @provider.populate(@book, query: @query)

            assert result.success?
            assert_equal [:ai_enrichment_queued], result.data_populated
          end

          test "falls back to the query's author names when the book has none" do
            book = ::Books::Book.create!(title: "Brand New")
            query = ImportQuery.new(title: "Brand New", author_names: ["Someone New"])
            ::Books::EnrichBookJob.expects(:perform_async).with(book.id, false, ["Someone New"])

            result = @provider.populate(book, query: query)

            assert result.success?
          end

          test "fails without a title" do
            @book.title = ""
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = @provider.populate(@book, query: @query)

            refute result.success?
            assert_includes result.errors, "Book title required for AI enrichment"
          end

          test "fails when neither the book nor the query has authors" do
            book = ::Books::Book.create!(title: "Nobody's Book")
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = @provider.populate(book, query: ImportQuery.new(title: "Nobody's Book"))

            refute result.success?
            assert_includes result.errors, "Book must have an author for AI enrichment"
          end

          test "fails when the book is not persisted" do
            book = ::Books::Book.new(title: "Unsaved")
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = @provider.populate(book, query: @query)

            refute result.success?
            assert_includes result.errors, "Book must be persisted before queuing AI enrichment"
          end

          test "works with a nil query for item-based imports" do
            ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false, ["Leo Tolstoy"])

            assert @provider.populate(@book, query: nil).success?
          end

          test "turns an enqueue error into a failure result" do
            ::Books::EnrichBookJob.stubs(:perform_async).raises(Redis::CannotConnectError, "down")

            result = @provider.populate(@book, query: @query)

            refute result.success?
            assert_match(/AI enrichment provider error: down/, result.errors.first)
          end
        end
      end
    end
  end
end
```

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/providers/ai_enrichment_test.rb`
Expected: FAIL with `NameError`.

- [ ] **Step 2: Write the provider**

`web-app/app/lib/data_importers/books/book/providers/ai_enrichment.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Async provider: queues Books::EnrichBookJob and returns at once.
        # Runs after OpenLibrary in the importer so the AI fills fewer blanks.
        #
        # A brand-new book has no book_authors rows (the OpenLibrary provider
        # deliberately creates no authors), so the query's author names ride
        # along to the job; the runner uses book.authors when they exist.
        class AiEnrichment < DataImporters::ProviderBase
          def populate(book, query:, match: nil)
            return failure_result(errors: ["Book title required for AI enrichment"]) if book.title.blank?

            author_names = book.authors.map(&:name)
            author_names = Array(query&.author_names).map(&:to_s).reject(&:blank?) if author_names.empty?
            return failure_result(errors: ["Book must have an author for AI enrichment"]) if author_names.empty?
            return failure_result(errors: ["Book must be persisted before queuing AI enrichment"]) unless book.persisted?

            ::Books::EnrichBookJob.perform_async(book.id, false, author_names)

            success_result(data_populated: [:ai_enrichment_queued])
          rescue => e
            failure_result(errors: ["AI enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
```

- [ ] **Step 3: Wire it into the importer, test first**

Add to `web-app/test/lib/data_importers/books/book/importer_test.rb`: in `setup`, after the existing stub line, add

```ruby
          # Sidekiq runs inline in tests; a real enqueue would run the AI task.
          ::Books::EnrichBookJob.stubs(:perform_async)
```

and, as a new test inside the class:

```ruby
        test "providers run Open Library first, then AI enrichment" do
          providers = Importer.new(query: ImportQuery.new(title: "X", author_names: ["Y"])).send(:providers)

          assert_equal [Providers::OpenLibrary, Providers::AiEnrichment], providers.map(&:class)
        end
```

If `Importer.new` requires different keyword arguments in `ImporterBase#initialize`, read `app/lib/data_importers/importer_base.rb` and build it the way `self.call` does; the assertion is what matters.

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/importer_test.rb -n /providers\ run/`
Expected: FAIL (only OpenLibrary).

Change `web-app/app/lib/data_importers/books/book/importer.rb` lines 34-36 to:

```ruby
        # OpenLibrary first: its fills are free and licensed, so the AI run
        # that follows has fewer blanks to fill.
        def providers
          @providers ||= [Providers::OpenLibrary.new, Providers::AiEnrichment.new]
        end
```

- [ ] **Step 4: Run the books importer tests and lint**

Run: `cd web-app && bin/rails test test/lib/data_importers/books && bundle exec standardrb app/lib/data_importers/books test/lib/data_importers/books`
Expected: green; no lint output.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/data_importers/books web-app/test/lib/data_importers/books
git commit -m "Books importer queues AI enrichment after Open Library

The provider carries the query's author names to the job because a
newly imported book has no book_authors rows yet."
```

---

### Task 10: Admin action, button, and E2E test

**Files:**
- Create: `web-app/app/lib/actions/admin/books/enrich_book.rb`
- Create: `web-app/test/lib/actions/admin/books/enrich_book_test.rb`
- Create: `web-app/e2e/tests/books/admin/books-enrich.spec.ts`
- Modify: `web-app/app/controllers/admin/books/books_controller.rb:97`
- Modify: `web-app/app/views/admin/books/books/show.html.erb` (button near line 17, new dialog after the merge dialog)
- Modify: `web-app/test/controllers/admin/books/books_controller_test.rb` (new tests after the merge block)

**Interfaces:**
- Consumes: `Books::EnrichBookJob.perform_async(book_id, force_research)` (Task 8); `Actions::Admin::BaseAction`.
- Produces: `Actions::Admin::Books::EnrichBook` with `fields[:force_research]` ("1"/"0"/true/false/nil).

- [ ] **Step 1: Write the failing action test**

`web-app/test/lib/actions/admin/books/enrich_book_test.rb`:

```ruby
require "test_helper"

module Actions
  module Admin
    module Books
      class EnrichBookTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @book = books_books(:war_and_peace)
        end

        test "is a non-destructive show-page action" do
          refute EnrichBook.destructive?
          assert EnrichBook.visible?(view: :show)
          refute EnrichBook.visible?(view: :index)
          assert_equal "Enrich With AI", EnrichBook.name
        end

        test "queues a knowledge run by default" do
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

          result = EnrichBook.call(user: @admin_user, models: [@book])

          assert result.success?
          assert_equal "Enrichment queued for War and Peace.", result.message
        end

        test "a checked force_research box queues a web search run" do
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, true)

          result = EnrichBook.call(user: @admin_user, models: [@book], fields: {"force_research" => "1"})

          assert result.success?
          assert_equal "Enrichment with web search queued for War and Peace.", result.message
        end

        test "an unchecked box is a knowledge run" do
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

          EnrichBook.call(user: @admin_user, models: [@book], fields: {force_research: "0"})
        end

        test "refuses more than one book" do
          ::Books::EnrichBookJob.expects(:perform_async).never

          result = EnrichBook.call(user: @admin_user, models: [@book, books_books(:crime_and_punishment)])

          assert result.error?
        end
      end
    end
  end
end
```

Run: `cd web-app && bin/rails test test/lib/actions/admin/books/enrich_book_test.rb`
Expected: FAIL with `NameError`.

- [ ] **Step 2: Write the action**

`web-app/app/lib/actions/admin/books/enrich_book.rb`:

```ruby
module Actions
  module Admin
    module Books
      # Every Books:: constant in here is root-anchored. Inside
      # Actions::Admin::Books, a bare `Books::Book` resolves to
      # Actions::Admin::Books::Book and raises a confusing NameError.
      class EnrichBook < Actions::Admin::BaseAction
        def self.name
          "Enrich With AI"
        end

        def self.message
          "Look up missing metadata and a description for this book in the background. Existing values are never overwritten."
        end

        def self.confirm_button_label
          "Enrich Book"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single book.") if models.count != 1

          book = models.first
          force = ActiveModel::Type::Boolean.new.cast(fields[:force_research] || fields["force_research"]) || false

          ::Books::EnrichBookJob.perform_async(book.id, force)

          succeed(force ? "Enrichment with web search queued for #{book.title}." : "Enrichment queued for #{book.title}.")
        end
      end
    end
  end
end
```

Run: `cd web-app && bin/rails test test/lib/actions/admin/books/enrich_book_test.rb`
Expected: 5 runs, 0 failures.

- [ ] **Step 3: Controller allowlist and tests**

In `web-app/app/controllers/admin/books/books_controller.rb` change

```ruby
  def allowed_action_names
    %w[MergeBook]
  end
```

to

```ruby
  def allowed_action_names
    %w[MergeBook EnrichBook]
  end
```

Add to `web-app/test/controllers/admin/books/books_controller_test.rb` after the merge tests:

```ruby
      # execute_action / enrich

      test "an admin can queue enrichment via execute_action" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

        post execute_action_admin_books_book_path(@book), params: {action_name: "EnrichBook"}

        assert_redirected_to admin_books_book_path(@book)
      end

      test "the force_research checkbox queues a web search run" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, true)

        post execute_action_admin_books_book_path(@book), params: {action_name: "EnrichBook", force_research: "1"}, as: :turbo_stream

        assert_response :success
        assert_includes response.body, 'target="flash"'
      end

      test "an unchecked force_research box is a knowledge run" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

        post execute_action_admin_books_book_path(@book), params: {action_name: "EnrichBook", force_research: "0"}

        assert_redirected_to admin_books_book_path(@book)
      end

      # Enrichment is not destructive, so write access is enough.
      test "a books domain editor can queue enrichment" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

        post execute_action_admin_books_book_path(@book), params: {action_name: "EnrichBook"}

        assert_redirected_to admin_books_book_path(@book)
      end
```

Run: `cd web-app && bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: green (the first three new tests fail before the allowlist edit if you run them first; after it, all pass).

- [ ] **Step 4: The button and the dialog**

In `web-app/app/views/admin/books/books/show.html.erb`, inside the `<div class="flex gap-2">` header block, after the `Edit` link's `<% end %>` and before the merge button's `<% if current_user_can_delete? %>`, add:

```erb
      <% if current_user_can_write? %>
        <button type="button"
                class="btn btn-outline"
                data-testid="enrich-book-button"
                onclick="document.getElementById('enrich-book-modal').showModal()">
          <span>Enrich With AI</span>
        </button>
      <% end %>
```

After the closing `</dialog>` of the merge modal (the end of the file), add:

```erb

<!-- Enrich Book Modal -->
<dialog id="enrich-book-modal" class="modal">
  <div class="modal-box">
    <h3 class="font-bold text-lg">Enrich With AI</h3>
    <p class="py-4">
      Looks up the first published year, original language, word count, page range,
      subtitle, alternate titles, origin country and a spoiler-free description for
      <strong><%= @book.title %></strong> in the background. Values already set are
      never overwritten. If the model does not know the book, a web search follows,
      within the daily budget.
    </p>

    <%= form_with url: execute_action_admin_books_book_path(@book),
                  method: :post,
                  class: "space-y-4",
                  data: {
                    controller: "modal-form",
                    modal_form_modal_id_value: "enrich-book-modal"
                  } do |f| %>
      <%= f.hidden_field :action_name, value: "EnrichBook" %>

      <div>
        <label class="label cursor-pointer justify-start gap-2">
          <%= f.check_box :force_research, class: "checkbox" %>
          <span>Search the web even if the model knows this book</span>
        </label>
        <label class="label">
          <span>A web search run costs about 15 cents and ignores the daily budget.</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="document.getElementById('enrich-book-modal').close()">Cancel</button>
        <%= f.submit "Enrich Book", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

Check the view renders: run `cd web-app && bin/rails test test/controllers/admin/books/books_controller_test.rb -n /show/` and expect green. Also run the daisyUI lint: `bin/rails test test/lint/daisyui_v4_classes_test.rb`.

- [ ] **Step 5: E2E test**

`web-app/e2e/tests/books/admin/books-enrich.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

// Drives the modal up to but not past submission: submitting would enqueue a
// real AI job against the development database and spend money.
test.describe("Books admin — enrich with AI", () => {
  test("the enrich button opens the modal on a book show page", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("enrich-book-button").click();

    await expect(page.getByRole("heading", { name: "Enrich With AI" })).toBeVisible();
    await expect(page.getByRole("checkbox", { name: /Search the web/ })).not.toBeChecked();
    await expect(page.getByRole("button", { name: "Enrich Book" })).toBeVisible();
  });

  test("cancel closes the modal without submitting", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("enrich-book-button").click();
    await page.getByRole("button", { name: "Cancel" }).click();

    await expect(page.getByRole("heading", { name: "Enrich With AI" })).not.toBeVisible();
  });
});
```

Run only if port 3000 is this checkout's server (see AGENTS.md "Port 3000 is shared"):

```bash
cd web-app && pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1); [ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If free: `yarn build:all && (bin/rails server &) && sleep 8 && yarn test:e2e --grep "enrich with AI"`. Expected: 2 passed. If another checkout holds the port, stop and report; do not kill it.

- [ ] **Step 6: Lint and commit**

Run: `cd web-app && bundle exec standardrb app/lib/actions/admin/books/enrich_book.rb app/controllers/admin/books/books_controller.rb test/lib/actions/admin/books/enrich_book_test.rb test/controllers/admin/books/books_controller_test.rb`

```bash
git add web-app/app/lib/actions/admin/books/enrich_book.rb web-app/app/controllers/admin/books/books_controller.rb web-app/app/views/admin/books/books/show.html.erb web-app/test/lib/actions/admin/books/enrich_book_test.rb web-app/test/controllers/admin/books/books_controller_test.rb web-app/e2e/tests/books/admin/books-enrich.spec.ts
git commit -m "Admin book page gets an Enrich With AI action

Non-destructive, so editors can run it. A checkbox forces the web
search run and ignores the daily budget."
```

---

### Task 11: Rake tasks

**Files:**
- Create: `web-app/lib/tasks/books/enrich.rake`

**Interfaces:**
- Consumes: `Books::EnrichBookJob` (Task 8), `Enrichment` (Task 3).
- Produces: `books:enrich[id_or_slug]` (runs the job inline), `books:enrich_missing[limit]` (enqueues).

- [ ] **Step 1: Write the rake file**

`web-app/lib/tasks/books/enrich.rake`:

```ruby
namespace :books do
  desc "Enrich one book with AI now: bin/rails books:enrich[123] or [some-slug]"
  task :enrich, [:book_id] => :environment do |_task, args|
    # Rake args are always strings, and Books::Book uses friendly_id with :finders --
    # so a bare .find("13") resolves by SLUG, and 137 books have purely numeric slugs
    # that shadow real ids. Decide explicitly instead of letting friendly_id guess.
    identifier = args[:book_id].to_s
    abort "Usage: bin/rails books:enrich[id-or-slug]" if identifier.blank?
    book = if identifier.match?(/\A\d+\z/)
      ::Books::Book.find_by!(id: identifier)
    else
      ::Books::Book.friendly.find(identifier)
    end

    puts "Enriching #{book.title} (##{book.id})..."
    Books::EnrichBookJob.new.perform(book.id)
    book.enrichments.order(:id).last(2).each do |row|
      puts "  #{row.mode}: #{row.outcome}#{" (#{row.reason})" if row.reason}#{" -- #{row.error}" if row.error}"
      row.facts.each do |name, entry|
        puts "    #{name}: #{entry["reason"]}#{" -> #{entry["value"].inspect}" if entry["applied"]}"
      end
    end
  end

  desc "Enqueue enrichment for books with no ledger row and no description: bin/rails books:enrich_missing[100]"
  task :enrich_missing, [:limit] => :environment do |_task, args|
    limit = args[:limit].to_i
    abort "Usage: bin/rails books:enrich_missing[limit] -- a limit is required; running wide is a decision" unless limit.positive?

    scope = ::Books::Book
      .where.not(id: Enrichment.where(enrichable_type: "Books::Book").select(:enrichable_id))
      .where.not(id: Description.where(describable_type: "Books::Book").select(:describable_id))
      .order(:id)
      .limit(limit)

    # pluck keeps the order; find_each would drop it and batch by primary key.
    ids = scope.pluck(:id)
    ids.each { |id| Books::EnrichBookJob.perform_async(id) }
    puts "Enqueued #{ids.size} book(s) for enrichment."
  end
end
```

- [ ] **Step 2: Smoke the task loading and a dry query**

Run: `cd web-app && bin/rails -T books:enrich`
Expected: both tasks listed.

Run: `cd web-app && RAILS_ENV=test bin/rails runner 'puts Books::Book.where.not(id: Enrichment.where(enrichable_type: "Books::Book").select(:enrichable_id)).where.not(id: Description.where(describable_type: "Books::Book").select(:describable_id)).count'`
Expected: an integer, no error (the test database has fixtures loaded only during tests, so the count may be 0; the point is that the SQL is valid).

Do **not** run `books:enrich` against development in this task: it makes real OpenAI calls. That is Shane's decision after merge.

- [ ] **Step 3: Lint and commit**

Run: `cd web-app && bundle exec standardrb lib/tasks/books/enrich.rake`

```bash
git add web-app/lib/tasks/books/enrich.rake
git commit -m "Add books:enrich and books:enrich_missing rake tasks"
```

---

### Task 12: Documentation

**Files:**
- Create: `docs/features/books_enrichment.md`
- Modify: `docs/features/ai_agents.md` (Supported Providers, Supported Tasks, Parameter Building, Extension Points)
- Modify: `docs/features/data_importers.md:85`, `:98`, and the Books Providers section

- [ ] **Step 1: Write the feature doc**

`docs/features/books_enrichment.md`:

```markdown
# Books AI Enrichment

Fills a `Books::Book`'s missing metadata and description from one background job, with a
web-search fallback for books the model does not know. Every run is recorded in the
`enrichments` table with per-field confidence.

Spec: `docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md`.

## How a book gets enriched

1. **Trigger.** One of three entry points enqueues `Books::EnrichBookJob`:
   - `DataImporters::Books::Book::Providers::AiEnrichment`, last in the importer's provider
     chain, passing the query's author names because a new book has no `book_authors` yet.
   - The **Enrich With AI** button on the admin book page (`Actions::Admin::Books::EnrichBook`),
     with a checkbox that forces the web-search run.
   - `bin/rails books:enrich[id]` (runs inline and prints the ledger) and
     `bin/rails books:enrich_missing[limit]` (enqueues books with no ledger row and no description).
   There is deliberately no model callback: `data_migration:all` creates 157k books.
2. **Knowledge run.** `Services::Books::EnrichBook` runs
   `Services::Ai::Tasks::Books::BookFactsTask` in `knowledge` mode on the `standard` role. One
   call returns `recognized`, an overall confidence, the description, and every fact with its
   own confidence.
3. **Review.** If a description came back, `DescriptionReviewTask` (`fast` role) checks it for
   spoilers and style and rewrites it if needed; `Services::Books::DescriptionCheck` then
   strips pasted citations and rejects em dashes, URLs, the title, and runaway lengths.
4. **Apply.** `Services::Books::ApplyBookFacts` fills blanks only: year, original language,
   word count, page range, subtitle, alternate titles (union), origin countries (only when the
   book has none), and the description as an `ai_generated` row. Book type and series are
   recorded but not applied. Nothing overwrites a value that is set, which is what protects
   human corrections. If `recognized` was false nothing is applied at all.
5. **Research fallback.** When `recognized` is false, or the overall confidence is `low`, or
   the book's year is at or past `config.x.ai.knowledge_cutoff_year` (in which case the
   knowledge call is skipped), the same task runs in `research` mode on the `research` role
   with the `web_search` tool forced. Citations land on the ledger row and the first becomes
   the description's `source_url`. `config.x.ai.research_daily_cap` bounds research runs per
   day; past it a `skipped` row is written. The admin force option ignores the cap.

## The ledger

`Enrichment` (`enrichments`): polymorphic `enrichable`, `kind` (`books.book_facts`), `mode`
(knowledge/research), `outcome` (applied, nothing_to_apply, unrecognized, skipped, failed),
`recognized`, `confidence`, `facts` JSON, `citations`, `provider`, `model`, `ai_chat_id`,
`error`, `reason`. Each `facts` entry is `{value, confidence, applied, reason}`; reasons are
`filled`, `already_set`, `null`, `invalid`, `no_match`, `not_applied_yet`, `unrecognized`,
`rejected`, `review_failed`. Useful queries:

```ruby
Enrichment.for_kind("books.book_facts").low_confidence_on(:word_count)
Enrichment.research.today.count                       # today's research spend, in runs
Enrichment.skipped.where(reason: "budget_exhausted")  # the research backlog
```

## Tuning

Everything is in `config/initializers/ai.rb`: the role-to-model map, the knowledge cutoff
year, and the daily research cap. The prompt rules live in `BookFactsTask#system_message`.

## Cost

Knowledge run on `gpt-6-sol`: under one cent. Review on `gpt-6-luna`: under a tenth of a cent.
Research run on `gpt-6-astra` with web search: about 15 cents (measured 2026-09-24).

## Not done here

Categories (genre, subject, location, and applying the recorded `book_type`), authors,
Goodreads, series, a ledger UI, and any catalog-wide backfill. See the spec's Non-goals.
```

- [ ] **Step 2: Update `ai_agents.md`**

Replace the `### Supported Providers` block with:

```markdown
### Supported Providers
- **OpenAI** (Complete) - Using Responses API with flex processing
  - Models are chosen per **role**, not per task: `config/initializers/ai.rb` maps `fast`,
    `standard`, `premium` and `research` to model IDs (currently `gpt-6-luna`, `gpt-6-sol`,
    `gpt-6-astra`, and `gpt-6-astra` with the `web_search` tool). A task declares
    `def task_role = :fast`; nothing in `app/` names a model ID.
  - Capabilities: json_mode, json_schema, function_calls, reasoning, tools (`:web_search`)
  - Special Features: Native structured outputs, flex tier pricing, url citations returned
    as `citations:` on the provider response

- **Anthropic** (Planned) - Claude models
- **Gemini** (Planned) - Google's AI models
```

Under `### Supported Tasks`, add a section:

```markdown
#### Enrichment
- **EnrichmentTask** - base for tasks that report facts with per-field confidence and never
  write to their parent; `mode: :knowledge` (standard role) or `mode: :research` (research
  role, web search forced)
- **Books::BookFactsTask** - metadata and a spoiler-free description for a book in one call
- **Books::DescriptionReviewTask** - spoiler and style review of a description (fast role)
- Runs are recorded in the `enrichments` table; see `docs/features/books_enrichment.md`
```

In the `### Parameter Building` comment block, change `model: "gpt-5-mini",` to `model: "gpt-6-sol",   # resolved from the task's role` and add after the `reasoning:` line:

```
#   tools: [{type: "web_search", search_context_size: "low"}],  # when the role or task asks
#   tool_choice: {type: "web_search"}                           # when force_tool? is true
```

In `### Adding New Tasks`, wherever the example shows `def task_model = "..."`, replace with `def task_role = :fast  # or :standard for recall-heavy prose`.

- [ ] **Step 3: Update `data_importers.md`**

Line 85: `| Books | Book | OpenLibrary | Complete |` becomes `| Books | Book | OpenLibrary, AiEnrichment | Complete |`.

Line 98: `- Uses Claude for natural language descriptions` becomes `- Uses OpenAI (the \`standard\` role, see \`ai_agents.md\`) for natural language descriptions`.

In `### Books Providers`, after the Open Library subsection, add:

```markdown
#### AI Enrichment (Async)
Queues `Books::EnrichBookJob` and returns `[:ai_enrichment_queued]`. Runs after Open Library so
the AI fills fewer blanks. Requires a title and either `book.authors` or the query's
`author_names` (a new book has no `book_authors` rows yet, so the names ride along to the job).
The job runs `Services::Books::EnrichBook`; see `docs/features/books_enrichment.md`.
```

- [ ] **Step 4: Run the whole suite, lint, commit**

Run: `cd web-app && bin/rails test && bundle exec standardrb`
Expected: 0 failures, 0 errors, no new warnings beyond the two known upstream sources, no lint output.

Run: `cd web-app && grep -rn "gpt-5-mini" app; echo "exit=$?"`
Expected: no matches, `exit=1`.

```bash
git add docs/features/books_enrichment.md docs/features/ai_agents.md docs/features/data_importers.md
git commit -m "Document books AI enrichment, model roles and tools"
```

---

## Self-review notes

- Spec §1 roles → Task 1. §2 tools → Task 2. §3 ledger → Task 3. §4 task and applier → Tasks 4–5. §5 description rules, review, check → Tasks 4, 6. §6 runner, job, provider, action, rake → Tasks 7–11. §8 tests are inside each task; the E2E test is in Task 10. §8 docs → Task 12. §9 error table: task failure (Task 7 test "a task failure..."), review failure (Task 7), rejected description (Task 7), no_match (Task 5), deleted book (Task 8), missing inputs (Task 7).
- Review Focus 1 → Task 7 "an unknown confidence string". 2 → Task 5 "does not write a second ai_generated description" plus Task 7's two-run test. 3 → Task 5 "origin countries with no match". 4 → Task 2 "returns no citations ... plain response" (mock without `annotations`). 5 → Task 10 "an unchecked box".
- Type consistency: `EnrichBook.call(book:, force_research:, author_names:)` matches Task 8's job call; `perform_async(book.id, false, author_names)` in Task 9 matches Task 8's signature; the action passes two arguments and the job's third defaults to `[]`. `ApplyBookFacts.call(book:, facts:, citations:, description:)` matches Task 7. The ledger entry keys are strings everywhere (`"value"`, `"confidence"`, `"applied"`, `"reason"`), and the fixture in Task 3 uses the same shape.
