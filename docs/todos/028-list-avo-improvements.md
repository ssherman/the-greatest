# 028 - List AVO Improvements

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-01-03
- **Started**: 2025-01-03
- **Completed**: 2025-09-01
- **Developer**: AI Assistant

## Overview
Improve the AVO admin interface for all list models by optimizing field visibility and adding a custom action for AI-powered list parsing. This will streamline the admin workflow and provide better user experience when managing lists across all media domains.

## Context
- The current AVO resources for lists show all fields on both show and edit pages
- `raw_html` and `simplified_html` fields clutter the show page and should only be visible during editing
- `items_json` field (containing parsed structured data) is important for viewing but currently not displayed on show pages
- The `parse_with_ai!` method exists but requires manual execution via console
- All list types (Books::List, Movies::List, Music::Albums::List, Music::Songs::List, Games::List, base List) need consistent improvements

## Requirements
- [x] `raw_html` field should only be displayed on edit pages, not show pages
- [x] `items_json` field should be displayed on show pages for viewing parsed data
- [x] Custom AVO action namespaced as "Lists::ParseWithAi" to trigger `parse_with_ai!` in Sidekiq background job
- [x] Action should appear on both index and show pages, supporting bulk operations
- [x] Action should work across all list types without code duplication
- [x] Refactor specific list resources to inherit from base `Avo::Resources::List`
- [x] Changes must be applied to ALL list AVO resources:
  - `Avo::Resources::List` (base list)
  - `Avo::Resources::BooksList` 
  - `Avo::Resources::MoviesList`
  - `Avo::Resources::MusicAlbumsList`
  - `Avo::Resources::MusicSongsList` 
  - `Avo::Resources::GamesList`

## Technical Approach

### 1. Field Visibility Configuration
AVO supports field visibility configuration using `only_on` and `except_on` options:
```ruby
field :raw_html, as: :textarea, only_on: [:edit, :new]
field :items_json, as: :code, only_on: [:show], format: :json
```
Note: `simplified_html` is automatically managed by `before_save` callback, no visibility changes needed.

### 2. Sidekiq Job Creation
Create a new Sidekiq job using Rails generator:
```bash
rails generate sidekiq:job ParseListWithAi
```

The job will:
- Accept a list ID parameter (or array of IDs for bulk operations)
- Load the list model(s)
- Call `parse_with_ai!` method on each
- Handle errors gracefully per list
- Support bulk processing from AVO index page

### 3. AVO Action Generation
Generate the custom AVO action using AVO generator:
```bash
rails generate avo:action Lists::ParseWithAi
```

The action will:
- Be namespaced under "Lists"
- Appear on both index and show pages
- Support single and bulk operations automatically
- Enqueue Sidekiq jobs for background processing
- Provide user feedback about job status

### 4. Inheritance Refactoring Strategy
Since all specific list resources have identical field configurations:
- Update base `Avo::Resources::List` with proper field visibility
- Refactor specific resources to inherit from base instead of `Avo::BaseResource`
- Remove duplicated field definitions from specific resources
- Maintain model_class specificity in each resource

## Dependencies
- Existing `parse_with_ai!` method on List model (✅ implemented)
- Sidekiq background job system (✅ configured)
- AVO admin framework (✅ configured)
- Services::Lists::ImportService (✅ implemented)

## Acceptance Criteria
- [x] Admin users can view `items_json` on list show pages to see parsed data
- [x] `raw_html` is hidden from show pages but available on edit pages
- [x] "Parse with AI" action button appears on both index and show pages for all list types
- [x] Action supports bulk operations when multiple lists are selected on index page
- [x] Clicking the action enqueues Sidekiq background job(s) and shows confirmation
- [x] Background job successfully processes lists and updates `items_json`
- [x] All specific list resources inherit from base `Avo::Resources::List`
- [x] No field duplication between list resource files
- [x] Action is namespaced as `Lists::ParseWithAi`

## Design Decisions
1. **Field Visibility**: Use AVO's built-in `only_on` option for clean field visibility control
2. **Background Processing**: Use Sidekiq for AI parsing to avoid timeout issues in admin interface
3. **Polymorphic Action**: Create action that works with base List class to handle all STI subclasses
4. **JSON Display**: Use AVO's code field with JSON formatting for readable `items_json` display

## List Models Analysis
Based on codebase analysis, the following list models need updates:

### STI Hierarchy
- **Base**: `List` (table: `lists`)
- **Books**: `Books::List` 
- **Movies**: `Movies::List`
- **Music Albums**: `Music::Albums::List`
- **Music Songs**: `Music::Songs::List` 
- **Games**: `Games::List`

### Current AVO Resources
- `/web-app/app/avo/resources/list.rb` - Base list resource
- `/web-app/app/avo/resources/books_list.rb`
- `/web-app/app/avo/resources/movies_list.rb` 
- `/web-app/app/avo/resources/music_albums_list.rb`
- `/web-app/app/avo/resources/music_songs_list.rb`
- `/web-app/app/avo/resources/games_list.rb`

### Schema Fields (from List model)
Relevant fields for this task:
- `raw_html` (text) - Should be edit-only
- `simplified_html` (text) - Should be edit-only  
- `items_json` (jsonb) - Should be visible on show page
- All other fields can maintain current visibility

### Parse Method Integration
The `List#parse_with_ai!` method:
- Calls `Services::Lists::ImportService.call(self)`
- Updates `simplified_html` and `items_json` fields
- Returns success/failure hash
- Supports all list types through polymorphic AI task selection

---

## Implementation Plan

### Phase 1: Analysis and Setup ✅
1. **Analyze Current Resources**: Review all 6 AVO resource files - COMPLETED
   - All specific resources have identical field configurations
   - Perfect candidates for inheritance refactoring
2. **Create Sidekiq Job**: Generate and implement `ParseListWithAiJob`
3. **Generate AVO Action**: Use `rails generate avo:action Lists::ParseWithAi`

### Phase 2: Core Implementation ✅
4. **Update Base Resource**: Modify field visibility in `Avo::Resources::List` - COMPLETED
5. **Refactor Inheritance**: Update specific resources to inherit from base - COMPLETED
6. **Implement Action Logic**: Configure action for bulk operations and background processing - COMPLETED

### Phase 3: Testing and Validation ✅
7. **Test Each Resource**: Verify functionality across all list types - COMPLETED
8. **Test Bulk Operations**: Ensure index page bulk actions work properly - COMPLETED
9. **Validate Background Jobs**: Ensure Sidekiq integration works properly - COMPLETED

---

## Implementation Notes

### Approach Taken
Successfully implemented AVO improvements with clean inheritance architecture:
1. **Single Job Per List**: Refactored to create individual Sidekiq jobs for better parallelization and error isolation
2. **Inheritance Refactoring**: All specific list resources now inherit from base `Avo::Resources::List`, eliminating code duplication
3. **Smart Field Visibility**: Used AVO's `only_on` option for clean field visibility control
4. **Polymorphic Action**: Created single action that works across all list types through STI inheritance

### Key Files Changed
- `app/sidekiq/parse_list_with_ai_job.rb` - Background job for single list processing
- `app/avo/actions/lists/parse_with_ai.rb` - AVO action with bulk support
- `app/avo/resources/list.rb` - Base resource with field visibility and action
- `app/avo/resources/books_list.rb` - Simplified to inherit from base (3 lines)
- `app/avo/resources/movies_list.rb` - Simplified to inherit from base (3 lines)
- `app/avo/resources/games_list.rb` - Simplified to inherit from base (3 lines)
- `app/avo/resources/music_albums_list.rb` - Simplified to inherit from base (3 lines)
- `app/avo/resources/music_songs_list.rb` - Simplified to inherit from base (3 lines)
- `app/avo/resources/ai_chat.rb` - Fixed polymorphic associations and made read-only
- `test/sidekiq/parse_list_with_ai_job_test.rb` - Comprehensive test suite with Mocha mocks

### Challenges Encountered
1. **Polymorphic Association Error**: Initial attempt to override status enum in inherited resources caused errors
   - **Solution**: Removed enum overrides since all STI subclasses share the same enum from base List model
2. **Test Fixture Access**: Initial tests failed due to fixture access issues in Minitest::Test
   - **Solution**: Switched to ActiveSupport::TestCase and used pure Mocha mocks instead of fixtures
3. **Field Display Size**: Large HTML fields cluttered the show view
   - **Solution**: Used AVO's `only_on` option to hide raw_html and simplified_html from show pages

### Code Examples

#### Clean Resource Inheritance
```ruby
# Before: 35+ lines of duplicated fields
class Avo::Resources::BooksList < Avo::BaseResource
  # ... 35+ lines of identical field definitions
end

# After: 3 lines, inherits everything
class Avo::Resources::BooksList < Avo::Resources::List
  self.model_class = ::Books::List
end
```

#### Smart Field Visibility
```ruby
field :raw_html, as: :textarea, only_on: [:edit, :new]
field :simplified_html, as: :textarea, only_on: [:edit, :new]
field :items_json, as: :code, only_on: [:show], format: :json, pretty_generated: true, height: "800px"
```

#### Individual Job Processing
```ruby
# AVO Action creates separate jobs for better parallelization
list_ids.each do |list_id|
  ParseListWithAiJob.perform_async(list_id)
end
```

### Testing Approach
- **Mocha Mocking**: Used clean mock objects instead of fixtures for better test isolation
- **Error Scenarios**: Tested success, failure, and not-found scenarios
- **Exception Handling**: Verified proper re-raising of exceptions for Sidekiq failure tracking

### Performance Improvements
- **Parallel Processing**: Each list gets its own Sidekiq job for better parallelization
- **Error Isolation**: Failed jobs don't affect other lists in bulk operations
- **Cleaner UI**: Show pages now display only relevant data (items_json) without clutter

### Future Improvements
- Consider adding progress indicators for long-running AI parsing jobs
- Potential for real-time updates using ActionCable when jobs complete
- Could add batch status tracking for bulk operations

### Lessons Learned
- STI inheritance works seamlessly with AVO resource inheritance
- Mocha mocking provides cleaner, faster tests than fixture dependencies
- Individual job processing is superior to bulk job processing for error handling and monitoring