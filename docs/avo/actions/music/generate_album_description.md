# Avo::Actions::Music::GenerateAlbumDescription

## Summary
AVO admin action that triggers AI description generation for selected music albums. Provides bulk processing capability through the admin interface.

## Associations
- Registered with `MusicAlbum` AVO resource
- Queues `Music::AlbumDescriptionJob` for processing
- Works with `Music::Album` models

## Public Methods

### `#handle(query:, fields:, current_user:, resource:, **)`
Processes the admin action for selected albums
- Parameters:
  - query (ActiveRecord::Relation) - Selected albums from admin interface
  - fields (Hash) - Form fields (not used)
  - current_user (User) - Admin user triggering action
  - resource (Avo::BaseResource) - AVO resource context
- Returns: void
- Side effects: Queues background jobs, provides user feedback

## Action Configuration
- Name: "Generate album description"
- Type: Bulk action (works on multiple selected records)
- Generated using: `bin/rails generate avo:action Music::GenerateAlbumDescription`

## User Feedback
- Success message indicates number of jobs queued
- Redirects back to album index with confirmation message

## Dependencies
- AVO gem for admin interface integration
- Music::AlbumDescriptionJob for background processing
- Sidekiq for job queuing

## Usage Pattern
1. Admin selects one or more albums in AVO interface
2. Chooses "Generate album description" action
3. Action queues background jobs for each selected album
4. User receives confirmation of queued jobs
5. Background jobs process AI description generation

## Integration Points
- Registered in `app/avo/resources/music_album.rb`
- Accessible from Music Album admin pages
- Provides manual trigger for AI description generation

## Security Considerations
- Only available to admin users through AVO interface
- No additional authorization checks beyond AVO's built-in admin access
