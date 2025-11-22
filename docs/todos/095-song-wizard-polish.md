# [095] - Song Wizard: Polish & Integration

## Status
- **Status**: Planned
- **Priority**: Medium
- **Created**: 2025-01-19
- **Part**: 10 of 10

## Overview
Final polish, integration points, error handling, and migration from old items_json workflow.

## Acceptance Criteria

### Integration Points
- [ ] "Create List with Wizard" button on Lists index
- [ ] "Re-process with Wizard" button on List show page
- [ ] Entry point from list show page
- [ ] Draft lists (wizard in progress) shown with badge
- [ ] Completed lists show verification stats

### Error Handling
- [ ] Network failures show retry button
- [ ] Job failures logged with details
- [ ] User-friendly error messages (no stack traces)
- [ ] Failed imports allow manual retry
- [ ] Wizard handles empty lists gracefully

### Mobile Responsiveness
- [ ] All steps render on mobile
- [ ] Tables scroll horizontally
- [ ] Actions accessible via overflow menu
- [ ] Progress indicator stacks vertically
- [ ] Touch-friendly tap targets

### Keyboard Shortcuts (Optional)
- [ ] j/k navigate items in review table
- [ ] v to verify current item
- [ ] s to skip current item

### Migration from items_json
- [ ] Document migration path
- [ ] Keep old Avo actions (deprecated)
- [ ] Add "Try New Wizard" banner in old flow

## Testing Checklist
- [ ] Complete flow: Source → Parse → Enrich → Validate → Review → Import → Complete
- [ ] MusicBrainz series fast path works
- [ ] All per-item actions work
- [ ] All bulk actions work
- [ ] Progress polling works
- [ ] Error states handled
- [ ] Mobile responsive
- [ ] 100-item list performs well

## Documentation
- [ ] Update `docs/admin/` with wizard docs
- [ ] Create user guide for non-technical users
- [ ] Document wizard_state structure
- [ ] Add troubleshooting section

## Performance
- [ ] Review step renders 100 items < 1s
- [ ] Enrichment job handles 100 items in ~2-3 min
- [ ] No N+1 queries in review step
- [ ] Polling adds minimal overhead

## Security
- [ ] Only admin/editor can access wizard
- [ ] CSRF protection on all forms
- [ ] Input sanitization on metadata edits
- [ ] Rate limiting on MusicBrainz API calls

## Related
- **Previous**: [094] Step 5: Import
- **Completes**: Song List Wizard implementation
- **Next**: Album List Wizard (separate track)
