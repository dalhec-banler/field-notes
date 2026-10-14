/// Tables that exist in the schema and that nothing writes (D-038 item 9;
/// docs/SCHEMA-RESERVED.md).
///
/// They were built ahead of features that never shipped — identity and
/// access from §4.2, devices and detections from §4.12 — and on every
/// database we have looked at they hold zero rows. A DROP is a migration,
/// so they stay in `schema.drift` exactly as they are until the next
/// migration that rebuilds anyway. Until then they are kept out of the code
/// paths: no sync triggers, no export, no dedupe sweep.
///
/// Adding a table here is a statement that no row in it is user data. Do
/// not add one without checking the live baseline counts first.
const kRetiredTables = <String>{
  'profiles',
  'memberships',
  'invites',
  'devices',
  'deployments',
  'detections',
};
