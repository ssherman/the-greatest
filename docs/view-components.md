---
layout: default
title: Getting started
parent: How-to guide
nav_order: 1
---

# Getting started

## Conventions

- Components are subclasses of `ViewComponent::Base` and live in `app/components`. It's common practice to create and inherit from an `ApplicationComponent` that's a subclass of `ViewComponent::Base`.
- Component names end in -`Component`.
- Component module names are plural, as for controllers and jobs: `Users::AvatarComponent`
- Name components for what they render, not what they accept. (`AvatarComponent` instead of `UserComponent`)

## Installation

In `Gemfile`, add:

```ruby
gem "view_component"
```

## Quick start

Use the component generator to create a new ViewComponent.

The generator accepts a component name and a list of arguments:

```console
bin/rails generate view_component:component Example title

      invoke  test_unit
      create  test/components/example_component_test.rb
      create  app/components/example_component.rb
      create  app/components/example_component.html.erb
```

Available options to customize the generator are documented on the [Generators](/guide/generators.html) page.

## Implementation

A ViewComponent is a Ruby class that inherits from `ViewComponent::Base`:

```ruby
class ExampleComponent < ViewComponent::Base
  erb_template <<-ERB
    <span title="<%= @title %>"><%= content %></span>
  ERB

  def initialize(title:)
    @title = title
  end
end
```

Content passed to a ViewComponent as a block is captured and assigned to the `content` accessor.

Rendered in a view as:

```erb
<%= render(ExampleComponent.new(title: "my title")) do %>
  Hello, World!
<% end %>
```

Returning:

```html
<span title="my title">Hello, World!</span>
```

## `#with_content`

Since 2.31.0
{: .label }

String content can also be passed to a ViewComponent by calling `#with_content`:

```erb
<%= render(ExampleComponent.new(title: "my title").with_content("Hello, World!")) %>
```

## Rendering from controllers

It's also possible to render ViewComponents in controllers:

```ruby
def show
  render(ExampleComponent.new(title: "My Title"))
end
```

_Note: Content can't be passed to a component via a block in controllers. Instead, use `with_content`._

When using turbo frames with [turbo-rails](https://github.com/hotwired/turbo-rails), set `content_type` as `text/html`:

```ruby
def create
  render(ExampleComponent.new, content_type: "text/html")
end
```

### Rendering ViewComponents to strings inside controller actions

When rendering the same component multiple times for later reuse, use `render_in`:

```rb
class PagesController < ApplicationController
  def index
    # Doesn't work: triggers a `AbstractController::DoubleRenderError`
    # @reusable_icon = render IconComponent.new("close")

    # Doesn't work: renders the whole index view as a string
    # @reusable_icon = render_to_string IconComponent.new("close")

    # Works: renders the component as a string
    @reusable_icon = IconComponent.new("close").render_in(view_context)
  end
end
```

### Rendering ViewComponents outside of the view context

To render ViewComponents outside of the view context (such as in a background job, markdown processor, etc), instantiate a Rails controller:

```ruby
ApplicationController.new.view_context.render(MyComponent.new)
```

---
layout: default
title: Collections
parent: How-to guide
---

# Collections

Since 2.1.0
{: .label }

Like [Rails partials](https://guides.rubyonrails.org/layouts_and_rendering.html#rendering-collections), it's possible to render a collection with ViewComponents, using `with_collection`:

```erb
<%= render(ProductComponent.with_collection(@products)) %>
```

```ruby
class ProductComponent < ViewComponent::Base
  def initialize(product:)
    @product = product
  end
end
```

[By default](https://github.com/viewcomponent/view_component/blob/89f8fab4609c1ef2467cf434d283864b3c754473/lib/view_component/base.rb#L249), the component name is used to define the parameter passed into the component from the collection.

## `with_collection_parameter`

Use `with_collection_parameter` to change the name of the collection parameter:

```ruby
class ProductComponent < ViewComponent::Base
  with_collection_parameter :item

  def initialize(item:)
    @item = item
  end
end
```

## Additional arguments

Additional arguments besides the collection are passed to each component instance:

```erb
<%= render(ProductComponent.with_collection(@products, notice: "hi")) %>
```

```ruby
class ProductComponent < ViewComponent::Base
  with_collection_parameter :item

  erb_template <<-ERB
    <li>
      <h2><%= @item.name %></h2>
      <span><%= @notice %></span>
    </li>
  ERB

  def initialize(item:, notice:)
    @item = item
    @notice = notice
  end
end
```

## Collection counter

Since 2.5.0
{: .label }

ViewComponent defines a counter variable matching the parameter name above, followed by `_counter`. To access the variable, add it to `initialize` as an argument:

```ruby
class ProductComponent < ViewComponent::Base
  erb_template <<-ERB
    <li>
      <%= @counter %> <%= @product.name %>
    </li>
  ERB

  def initialize(product:, product_counter:)
    @product = product
    @counter = product_counter
  end
end
```

## Collection iteration context

Since 2.33.0
{: .label }

ViewComponent defines an iteration variable matching the parameter name above, followed by `_iteration`. This gives contextual information about the iteration to components within the collection (`#size`, `#index`, `#first?`, and `#last?`).

To access the variable, add it to `initialize` as an argument:

```ruby
class ProductComponent < ViewComponent::Base
  erb_template <<-ERB
    <li class="<%= "featured" if @iteration.first? %>">
      <%= @product.name %>
    </li>
  ERB

  def initialize(product:, product_iteration:)
    @product = product
    @iteration = product_iteration
  end
end
```

## Spacer components

Since 3.20.0
{: .label }

Set `:spacer_component` as an instantiated component to render between items:

```erb
<%= render(ProductComponent.with_collection(@products, spacer_component: SpacerComponent.new)) %>
```

Which will render the SpacerComponent component between `ProductComponent`s.

---
layout: default
title: Conditional rendering
parent: How-to guide
---

# Conditional rendering

Since 1.8.0
{: .label }

Components can implement a `#render?` method to be called after initialization to determine if the component should render.

Traditionally, the logic for whether to render a view could go in either the component template:

```erb
<% if user.requires_confirmation? %>
  <div class="alert">Please confirm your email address.</div>
<% end %>
```

or the view that renders the component:

```erb
<% if current_user.requires_confirmation? %>
  <%= render(ConfirmEmailComponent.new(user: current_user)) %>
<% end %>
```

Using the `#render?` hook simplifies the view:

```ruby
class ConfirmEmailComponent < ViewComponent::Base
  erb_template <<-ERB
    <div class="banner">
      Please confirm your email address.
    </div>
  ERB

  def initialize(user:)
    @user = user
  end

  def render?
    @user.requires_confirmation?
  end
end
```

```erb
<%= render(ConfirmEmailComponent.new(user: current_user)) %>
```

_To assert whether a component has been rendered, use `assert_component_rendered` / `refute_component_rendered` from `ViewComponent::TestHelpers`._

---
layout: default
title: Generators
parent: How-to guide
---

# Generators

The generator accepts a component name and a list of arguments.

To create an `ExampleComponent` with `title` and `content` attributes:

```console
bin/rails generate view_component:component Example title content

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  erb
      create    app/components/example_component.html.erb
```

## Generating namespaced components

To generate a namespaced `Sections::ExampleComponent`:

```console
bin/rails generate view_component:component Sections::Example title content

      create  app/components/sections/example_component.rb
      invoke  test_unit
      create    test/components/sections/example_component_test.rb
      invoke  erb
      create    app/components/sections/example_component.html.erb
```

## Options

You can specify options when running the generator. To alter the default values project-wide, define the configuration settings described in [API docs](/api.html#configuration).

Generated ViewComponents are added to `app/components` by default. Set `config.view_component.generate.path` to use a different path.

```ruby
# config/application.rb
config.view_component.generate.path = "app/views/components"
config.eager_load_paths << Rails.root.join("app/views/components")
```

### Override template engine

ViewComponent includes template generators for the `erb`, `haml`, and `slim` template engines and will default to the template engine specified in `config.generators.template_engine`.

```console
bin/rails generate view_component:component Example title --template-engine slim

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  slim
      create    app/components/example_component.html.slim
```

### Override test framework

By default, `config.generators.test_framework` is used.

```console
bin/rails generate view_component:component Example title --test-framework rspec

      create  app/components/example_component.rb
      invoke  rspec
      create    spec/components/example_component_spec.rb
      invoke  erb
      create    app/components/example_component.html.erb
```

### Generate a [preview](/guide/previews.html)

Since 2.25.0
{: .label }

```console
bin/rails generate view_component:component Example title --preview

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  preview
      create    test/components/previews/example_component_preview.rb
      invoke  erb
      create    app/components/example_component.html.erb
```

### Generate a [Stimulus controller](/guide/javascript_and_css.html#stimulus)

Since 2.38.0
{: .label }

```console
bin/rails generate view_component:component Example title --stimulus

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  stimulus
      create    app/components/example_component_controller.js
      invoke  erb
      create    app/components/example_component.html.erb
```

To always generate a Stimulus controller, set `config.view_component.generate.stimulus_controller = true`.

To generate a TypeScript controller instead of a JavaScript controller, either:

- Pass the `--typescript` option
- Set `config.view_component.generate.typescript = true`

### Generate [locale files](/guide/translations.html)

Since 2.47.0
{: .label }

```console
bin/rails generate view_component:component Example title --locale

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  locale
      create    app/components/example_component.yml
      invoke  erb
      create    app/components/example_component.html.erb
```

To always generate locale files, set `config.view_component.generate.locale = true`.

To generate translations in distinct locale files, set `config.view_component.generate.distinct_locale_files = true` to generate as many files as configured in `I18n.available_locales`.

### Place the view in a sidecar directory

Since 2.16.0
{: .label }

```console
bin/rails generate view_component:component Example title --sidecar

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  erb
      create    app/components/example_component/example_component.html.erb
```

To always generate in the sidecar directory, set `config.view_component.generate.sidecar = true`.

### Use [inline template](/guide/templates.html#inline) (no template file)

```console
bin/rails generate view_component:component Example title --inline

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  erb
```

### Use [call method](/guide/templates.html#call) (no template file)

```console
bin/rails generate view_component:component Example title --call

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  erb
```

### Specify the parent class

Since 2.41.0
{: .label }

By default, `ApplicationComponent` is used if defined, `ViewComponent::Base` otherwise.

```console
bin/rails generate view_component:component Example title content --parent MyBaseComponent

      create  app/components/example_component.rb
      invoke  test_unit
      create    test/components/example_component_test.rb
      invoke  erb
      create    app/components/example_component.html.erb
```

To always use a specific parent class, set `config.view_component.parent_class = "MyBaseComponent"`.

### Skip collision check

The generator prevents naming collisions with existing components. To skip this check and force the generator to run, use the `--skip-collision-check` or `--force` option.

---
layout: default
title: Helpers
parent: How-to guide
---

# Helpers

Helpers must be included to be used:

```ruby
module IconHelper
  def icon(name)
    tag.i data: {feather: name.to_s}
  end
end

class UserComponent < ViewComponent::Base
  include IconHelper

  def profile_icon
    icon :user
  end
end
```

## Proxy

Since 1.5.0
{: .label }

Or, access helpers through the `helpers` proxy:

```ruby
class UserComponent < ViewComponent::Base
  def profile_icon
    helpers.icon :user
  end
end
```

Which can be used with `delegate`:

```ruby
class UserComponent < ViewComponent::Base
  delegate :icon, to: :helpers

  def profile_icon
    icon :user
  end
end
```

## Nested URL helpers

Rails nested URL helpers implicitly depend on the current `request` in certain cases. Since ViewComponent is built to enable reusing components in different contexts, nested URL helpers should be passed their options explicitly:

```ruby
# bad
edit_user_path # implicitly depends on current request to provide `user`

# good
edit_user_path(user: current_user)
```

Alternatively, use the `helpers` proxy:

```ruby
helpers.edit_user_path
```

---
layout: default
title: Slots
parent: How-to guide
---

# Slots

Since 2.12.0
{: .label }

In addition to the `content` accessor, ViewComponents can accept content through slots. Think of slots as a way to render multiple blocks of content, including other components.

Slots are defined with `renders_one` and `renders_many`:

- `renders_one` defines a slot that will be rendered at most once per component: `renders_one :header`
- `renders_many` defines a slot that can be rendered multiple times per-component: `renders_many :posts`

If a second argument isn't provided to these methods, a **passthrough slot** is registered. Any content passed through can be rendered inside these slots without restriction.

For example:

```ruby
# blog_component.rb
class BlogComponent < ViewComponent::Base
  renders_one :header
  renders_many :posts
end
```

To render a `renders_one` slot, call the name of the slot.

To render a `renders_many` slot, iterate over the name of the slot:

```erb
<%# blog_component.html.erb %>
<h1><%= header %></h1>

<% posts.each do |post| %>
  <%= post %>
<% end %>
```

```erb
<%# index.html.erb %>
<%= render BlogComponent.new do |component| %>
  <% component.with_header do %>
    <%= link_to "My blog", root_path %>
  <% end %>

  <% BlogPost.all.each do |blog_post| %>
    <% component.with_post do %>
      <%= link_to blog_post.name, blog_post.url %>
    <% end %>
  <% end %>
<% end %>
```

Returning:

```erb
<h1><a href="/">My blog</a></h1>

<a href="/blog/first-post">First post</a>
<a href="/blog/second-post">Second post</a>
```

## Predicate methods

Since 2.50.0
{: .label }

To test whether a slot has been passed to the component, use the provided `#{slot_name}?` method.

```erb
<%# blog_component.html.erb %>
<% if header? %>
  <h1><%= header %></h1>
<% end %>

<% if posts? %>
  <div class="posts">
    <% posts.each do |post| %>
      <%= post %>
    <% end %>
  </div>
<% else %>
  <p>No post yet.</p>
<% end %>
```

## Component slots

Slots can also render other components. Pass the name of a component as the second argument to define a component slot.

Arguments passed when calling a component slot will be used to initialize the component and render it. A block can also be passed to set the component's content.

```ruby
# blog_component.rb
class BlogComponent < ViewComponent::Base
  # Since `HeaderComponent` is nested inside of this component, we have to
  # reference it as a string instead of a class name.
  renders_one :header, "HeaderComponent"

  # `PostComponent` is defined in another file, so we can refer to it by class name.
  renders_many :posts, PostComponent

  class HeaderComponent < ViewComponent::Base
    attr_reader :classes

    def initialize(classes:)
      @classes = classes
    end

    def call
      content_tag :h1, content, {class: classes}
    end
  end
end
```

```erb
<%# blog_component.html.erb %>
<%= header %>

<% posts.each do |post| %>
  <%= post %>
<% end %>
```

```erb
<%# index.html.erb %>
<%= render BlogComponent.new do |component| %>
  <% component.with_header(classes: "") do %>
    <%= link_to "My Site", root_path %>
  <% end %>

  <% component.with_post(title: "My blog post") do %>
    Really interesting stuff.
  <% end %>

  <% component.with_post(title: "Another post!") do %>
    Blog every day.
  <% end %>
<% end %>
```

## Referencing slots

As the content passed to slots is registered after a component is initialized, it can't be referenced in an initializer. One way to reference slot content is using the `before_render` [lifecycle method](/guide/lifecycle):

```ruby
# blog_component.rb
class BlogComponent < ViewComponent::Base
  renders_one :image
  renders_many :posts

  def before_render
    @post_container_classes = "PostContainer--hasImage" if image.present?
  end
end
```

```erb
<%# blog_component.html.erb %>
<% posts.each do |post| %>
  <div class="<%= @post_container_classes %>">
    <%= image if image? %>
    <%= post %>
  </div>
<% end %>
```

## Lambda slots

It's also possible to define a slot as a lambda that returns content to be rendered (either a string or a ViewComponent instance). Lambda slots are useful in cases where writing another component may be unnecessary, such as working with helpers like `content_tag` or as wrappers for another ViewComponent with specific default values:

```ruby
class BlogComponent < ViewComponent::Base
  renders_one :header, ->(classes:) do
    # This isn't complex enough to be its own component yet, so we'll use a
    # lambda slot. If it gets much bigger, it should be extracted out to a
    # ViewComponent and rendered here with a component slot.
    content_tag :h1 do
      link_to title, root_path, {class: classes}
    end
  end

  # It's also possible to return another ViewComponent with preset default values:
  renders_many :posts, ->(title:, classes:) do
    PostComponent.new(title: title, classes: "my-default-class " + classes)
  end
end
```

Lambda slots are able to access state from the parent ViewComponent:

```ruby
class TableComponent < ViewComponent::Base
  renders_one :header, -> do
    HeaderComponent.new(selectable: @selectable)
  end

  def initialize(selectable: false)
    @selectable = selectable
  end
end
```

To provide content for a lambda slot via a block, add a block parameter. Render the content by calling the block's `call` method, or by passing the block directly to `content_tag`:

```ruby
class BlogComponent < ViewComponent::Base
  renders_one :header, ->(classes:, &block) do
    content_tag :h1, class: classes, &block
  end
end
```

_Note: While a lambda is called when the `with_*` method is called, a returned component isn't rendered until first use._

## Rendering collections

Since 2.23.0
{: .label }

`renders_many` slots can also be passed a collection, using the plural setter (`links` in this example):

```ruby
# navigation_component.rb
class NavigationComponent < ViewComponent::Base
  renders_many :links, "LinkComponent"

  class LinkComponent < ViewComponent::Base
    def initialize(name:, href:)
      @name = name
      @href = href
    end
  end
end
```

```erb
<%# navigation_component.html.erb %>
<% links.each do |link| %>
  <%= link %>
<% end %>
```

```erb
<%# index.html.erb %>
<%= render(NavigationComponent.new) do |component| %>
  <% component.with_links([
    { name: "Home", href: "/" },
    { name: "Pricing", href: "/pricing" },
    { name: "Sign Up", href: "/sign-up" },
  ]) %>
<% end %>
```

## `#with_SLOT_NAME_content`

Since 3.0.0
{: .label }

Assuming no arguments need to be passed to the slot, slot content can be set with `#with_SLOT_NAME_content`:

```erb
<%= render(BlogComponent.new.with_header_content("My blog")) %>
```

## `#with_content`

Since 2.31.0
{: .label }

Slot content can also be set using `#with_content`:

```erb
<%= render BlogComponent.new do |component| %>
  <% component.with_header(classes: "title").with_content("My blog") %>
<% end %>
```

## Polymorphic slots

Since 2.42.0
{: .label }

Polymorphic slots can render one of several possible slots.

For example, consider this list item component that can be rendered with either an icon or an avatar visual. The `visual` slot is passed a hash mapping types to slot definitions:

```ruby
class ListItemComponent < ViewComponent::Base
  renders_one :visual, types: {
    icon: IconComponent,
    avatar: lambda { |**system_arguments|
      AvatarComponent.new(size: 16, **system_arguments)
    }
  }
end
```

**Note**: the `types` hash's values can be any valid slot definition, including a component class, string, or lambda.

Filling in the `visual` slot is done by calling the appropriate slot method:

```erb
<%= render ListItemComponent.new do |component| %>
  <% component.with_visual_avatar(src: "http://some-site.com/my_avatar.jpg", alt: "username") do %>
    Profile
  <% end >
<% end %>
<%= render ListItemComponent.new do |component| %>
  <% component.with_visual_icon(icon: :key) do %>
    Security Settings
  <% end >
<% end %>
```

To see whether a polymorphic slot has been passed to the component, use the `#{slot_name}?` method.

```erb
<% if visual? %>
  <%= visual %>
<% else %>
  <span class="visual-placeholder">N/A</span>
<% end %>
```

### Custom polymorphic slot setters

Since 3.1.0
{: .label }

Customize slot setters by specifying a nested hash for the `type` value:

```ruby
class ListItemComponent < ViewComponent::Base
  renders_one :visual, types: {
    icon: {renders: IconComponent, as: :icon_visual},
    avatar: {
      renders: lambda { |**system_arguments| AvatarComponent.new(size: 16, **system_arguments) },
      as: :avatar_visual
    }
  }
end
```

The setters are now `#with_icon_visual` and `#with_avatar_visual` instead of the default `#with_visual_icon` and `#with_visual_avatar`. The slot getter remains `#visual`.

## `#default_SLOT_NAME`

Since 4.0.0
{: .label }

To provide a default value for a slot, define a `default_SLOT_NAME` method:

```ruby
class SlotableDefaultComponent < ViewComponent::Base
  renders_one :header

  def default_header
    "Hello, World!"
  end
end
```

`default_SLOT_NAME` can also return a component instance to be rendered:

```ruby
class SlotableDefaultInstanceComponent < ViewComponent::Base
  renders_one :header

  def default_header
    MyComponent.new
  end
end
```

---
layout: default
title: Best practices
nav_order: 5
---

# Best practices

## Philosophy

### Why ViewComponent exists

ViewComponent was created to help manage the growing complexity of the GitHub.com view layer, which accumulated thousands of templates over the years, almost entirely through copy-pasting. A lack of abstraction made it challenging to make sweeping design, accessibility, and behavior improvements.

ViewComponent provides a way to isolate common UI patterns for reuse, helping to improve the quality and consistency of Rails applications.

### ViewComponent is to UI what ActiveRecord is to SQL

ViewComponent brings [conceptual compression](https://m.signalvnoise.com/conceptual-compression-means-beginners-dont-need-to-know-sql-hallelujah/) to the practice of building user interfaces.

### ViewComponent exposes existing complexity

Converting an existing view/partial to a ViewComponent often exposes existing complexity. For example, a ViewComponent may need numerous arguments to be rendered, revealing the number of dependencies in the existing view code.

This is good! Refactoring to use ViewComponent improves comprehension and provides a foundation for further improvement.

## Organization

### Two types of ViewComponents

ViewComponents typically come in two forms: general-purpose and application-specific.

#### General-purpose ViewComponents

General-purpose ViewComponents implement common UI patterns, such as a button, form, or modal. GitHub open-sources these components as [Primer ViewComponents](https://github.com/primer/view_components).

#### Application-specific ViewComponents

Application-specific ViewComponents translate a domain object (such as an `ActiveRecord` model or an API response modeled as a Plain Old Ruby Object) into one or more general-purpose components.

For example, `User::AvatarComponent` accepts a `User` ActiveRecord object and renders a `DesignSystem::AvatarComponent`.

### Extract general-purpose ViewComponents

"Good frameworks are extracted, not invented" - [DHH](https://dhh.dk/arc/000416.html)

Just as ViewComponent itself was extracted from GitHub.com, general-purpose components are best extracted once they've proven helpful across more than one area:

1. Single use-case component implemented.
2. Component adapted for general use in multiple locations in the application.
3. Component extracted into a general-purpose ViewComponent in `app/lib` or a separate gem.

### Reduce permutations

When building ViewComponents, look for opportunities to consolidate similar patterns into a single implementation. Consider following standard DRY practices, abstracting once there are three or more similar instances.

### Avoid one-offs

Aim to minimize the amount of single-use view code. Every new component introduced adds to application maintenance burden.

### Use -Component suffix

While it means class names are longer and perhaps less readable, including the -`Component` suffix in component names makes it clear that the class is a component, following Rails convention of using suffixes for all non-model objects.

## Implementation

### Avoid inheritance

Having one ViewComponent inherit from another leads to confusion, especially when each component has its own template. Instead, [use composition](https://thoughtbot.com/blog/reusable-oo-composition-vs-inheritance) to wrap one component with another.

### When to use a ViewComponent for an entire route

ViewComponents have less value in single-use cases like replacing a `show` view. However, it can make sense to render an entire route with a ViewComponent when unit testing is valuable, such as for views with many permutations from a state machine.

When migrating an entire route to use ViewComponents, work from the bottom up, extracting portions of the page into ViewComponents first.

### Test against rendered content, not instance methods

ViewComponent tests should use `render_inline` and assert against the rendered output. While it can be useful to test specific component instance methods directly, it's more valuable to write assertions against what's shown to the end user:

```ruby
# good
render_inline(MyComponent.new)
assert_text("Hello, World!")

# bad
assert_equal(MyComponent.new.message, "Hello, World!")
```

### Most ViewComponent instance methods can be private

Most ViewComponent instance methods can be private, as they will still be available in the component template:

```ruby
# good
class MyComponent < ViewComponent::Base
  private

  def method_used_in_template
  end
end

# bad
class MyComponent < ViewComponent::Base
  def method_used_in_template
  end
end
```

### Prefer ViewComponents over partials

Use ViewComponents in place of partials.

### Prefer ViewComponents over HTML-generating helpers

Use ViewComponents in place of helpers that return HTML.

### Avoid global state

The more a ViewComponent is dependent on global state (such as request parameters or the current URL), the less likely it's to be reusable. Avoid implicit coupling to global state, instead passing it into the component explicitly:

```ruby
# good
class MyComponent < ViewComponent::Base
  def initialize(name:)
    @name = name
  end
end

# bad
class MyComponent < ViewComponent::Base
  def initialize
    @name = params[:name]
  end
end
```

Thorough unit testing is a good way to ensure decoupling from global state.

### Avoid inline Ruby in ViewComponent templates

Avoid writing inline Ruby in ViewComponent templates. Try using an instance method on the ViewComponent instead:

```ruby
# good
class MyComponent < ViewComponent::Base
  attr_accessor :name

  def message
    "Hello, #{name}!"
  end
end
```

```erb
<%# bad %>
<% message = "Hello, #{name}" %>
```

### Prefer slots over passing markup as an argument

Prefer using slots for providing markup to components. Passing markup as an argument bypasses the HTML sanitization provided by Rails, creating the potential for security issues:

```erb
# good
<%= render(MyComponent.new) do |component| %>
  <% component.with_name do %>
    <strong>Hello, world!</strong>
  <% end %>
<% end %>
```

```erb
# bad
<%= render MyComponent.new(name: "<strong>Hello, world!</strong>".html_safe) %>
```