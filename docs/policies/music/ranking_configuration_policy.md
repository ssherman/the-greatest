# Music::RankingConfigurationPolicy

## Summary
Pundit policy for ranking configuration authorization. Ranking configurations are system-level resources that require `manage` permission for all write operations.

## Domain
`"music"`

## Permission Requirements

**Important**: Ranking configurations require `manage` permission for all write operations. This is stricter than normal resources.

- **Global Admin**: Full access (manage = yes)
- **Global Editor**: Read-only access (manage = no)
- **Domain Admin**: Full access (manage = yes)
- **Domain Editor/Moderator/Viewer**: Read-only access

## Methods

### `#index?` / `#show?`
Standard read access - uses `global_role?` or `domain_role.can_read?`
- Allows: Global admin, global editor, any domain role

### `#create?` / `#new?`
Requires manage permission.
- Returns: `manage?` (global_admin? || domain_role.can_manage?)
- Allows: Global admin, domain admin only

### `#update?` / `#edit?`
Requires manage permission.
- Returns: `manage?`
- Allows: Global admin, domain admin only

### `#destroy?`
Requires manage permission.
- Returns: `manage?`
- Allows: Global admin, domain admin only

### `#execute_action?`
For executing custom actions on ranking configurations.
- Returns: `manage?`
- Allows: Global admin, domain admin only

### `#index_action?`
For bulk/index-level actions like refreshing all rankings.
- Returns: `manage?`
- Allows: Global admin, domain admin only

## Related Classes
- `ApplicationPolicy` - Base policy
- `Music::Albums::RankingConfiguration`, `Music::Artists::RankingConfiguration`, `Music::Songs::RankingConfiguration` - The models
- `Admin::Music::RankingConfigurationsController` - Controller using this policy

## Rationale
Ranking configurations affect the entire ranking algorithm output for a domain. Changes can significantly impact the published rankings, so write access is restricted to administrators only.
