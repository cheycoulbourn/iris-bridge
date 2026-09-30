# Chat post references (0.3.1)

`postReferences` in the helper's capabilities advertises the additive `post.referenced` event on the v3
stream. The v2 protocol version, pairing, certificate, port and existing action envelopes are unchanged.

```json
{
  "type": "post.referenced",
  "threadId": "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77",
  "turnId": "t1",
  "seq": 2,
  "postID": "C0000000-0000-4000-8000-000000000001",
  "profileID": "A1B2C3D4-0000-4000-8000-000000000001"
}
```

The shared ToolService emits this reference for either Claude or Codex only after `iris_get_post` succeeds.
IrisReadTools supplies the post id from the snapshot record actually returned and that same snapshot's
profile id; both must be valid UUIDs. This metadata stays internal to the helper, so the MCP result shape
does not change. Missing posts, failed reads, other read tools and terminal-agent reads emit no event.

SessionManager rechecks the active thread/turn before publishing. It suppresses duplicate reads of the
same profile/post within one turn and drops references whose turn has completed or been replaced. The
event uses the thread's normal sequence and replay log. Only the canonical UUIDs are persisted in the
reference event, never the post title, script or complete tool response.

The app must check that profileID matches the chat's profile/current workspace, resolve the post from its
own data, and ignore missing or mismatched records. It displays a post card beside the chat's existing
review and Undo cards. No planner mutation or approval occurs because of a reference.

Iris's previous v3 parser maps an unfamiliar message type to `.unknown(type)` and ignores it. A later
known event advances its thread cursor normally, so the new type is backward compatible; old apps simply
do not display the card. The optional capability lets compatible apps advertise reference support.

Verification covers both provider paths, lowercase-id canonicalization, failed/missing/profile-mismatch
reads, malformed snapshot ids, terminal/inactive chat reads, per-turn deduplication, replay and late
callbacks after completion or replacement. App record resolution and card rendering are verified in the
companion app change.
