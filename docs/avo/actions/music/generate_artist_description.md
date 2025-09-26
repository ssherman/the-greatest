# Avo::Actions::Music::GenerateArtistDescription

## Summary
AVO admin action that triggers AI description generation for selected music artists. Provides bulk processing capability through the admin interface.

## Associations
- Registered with `MusicArtist` AVO resource
- Queues `Music::ArtistDescriptionJob` for processing
- Works with `Music::Artist` models

## Public Methods

### `#handle(query:, fields:, current_user:, resource:, **)`
Processes the admin action for selected artists
- Parameters:
  - query (ActiveRecord::Relation) - Selected artists from admin interface
  - fields (Hash) - Form fields (not used)
  - current_user (User) - Admin user triggering action
  - resource (Avo::BaseResource) - AVO resource context
- Returns: void
- Side effects: Queues background jobs, provides user feedback

## Action Configuration
- Name: "Generate artist description"
- Type: Bulk action (works on multiple selected records)
- Generated using: `bin/rails generate avo:action Music::GenerateArtistDescription`

## User Feedback
- Success message indicates number of jobs queued
- Redirects back to artist index with confirmation message

## Dependencies
- AVO gem for admin interface integration
- Music::ArtistDescriptionJob for background processing
- Sidekiq for job queuing

## Usage Pattern
1. Admin selects one or more artists in AVO interface
2. Chooses "Generate artist description" action
3. Action queues background jobs for each selected artist
4. User receives confirmation of queued jobs
5. Background jobs process AI description generation

## Integration Points
- Registered in `app/avo/resources/music_artist.rb`
- Accessible from Music Artist admin pages
- Provides manual trigger for AI description generation

## Security Considerations
- Only available to admin users through AVO interface
- No additional authorization checks beyond AVO's built-in admin access
