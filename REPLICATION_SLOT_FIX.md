# Replication Slot Fix - Analysis & Plan

## Problem Statement

When large amounts of data are pushed to tables NOT in the Sequin publication, the replication slot enters a death spiral:
1. Heartbeat messages can't arrive within the timeout (configurable, default 10 min)
2. High watermark never advances downstream, so `restart_wal_cursor` can't advance
3. Postgres retains WAL because `confirmed_flush_lsn` / `restart_lsn` are stuck

## Root Cause Analysis

### The Core Issue

Sequin conflates "receiving WAL" with "having publication-matching messages". These are decoupled in Postgres:
- Postgres sends Begin/Commit for ALL transactions (even non-publication ones)
- Postgres sends keepalives with current `wal_end` position
- But only publication-matching changes (I/U/D) are sent as logical messages

When non-publication WAL floods in:
- SlotProducer sees keepalives with advancing `wal_end`
- SlotProducer sees Begin/Commit (`last_commit_lsn` updates)
- But NO publication messages arrive
- So `last_dispatched_wal_cursor` stays nil
- So batch markers are never sent
- So `last_flushed_high_watermark` in SlotProcessorServer never advances
- So `restart_wal_cursor!` returns nil (or stale value)
- So ACKs to Postgres don't advance the slot

### The Full Cursor Flow (Important Context)

```
SlotProducer                    SlotProcessorServer              SlotMessageStore
─────────────────────────────────────────────────────────────────────────────────
receives WAL messages
  ↓
accumulates in accumulated_messages
  ↓ (on demand)
dispatches → last_dispatched_wal_cursor
  ↓ (on timer)
BatchMarker{high_watermark}  →  flush_messages()
                                  ↓
                                last_flushed_high_watermark
                                  ↓
                                put_high_watermark_wal_cursor() → stores track watermark
                                                                    ↓
                                                                  messages persisted
                                                                    ↓
                              restart_wal_cursor!() ←────────── min_unpersisted_wal_cursors()
                                  ↓
                              returns min(store cursors)
                                  ↓
SlotProducer.send_ack(restart_wal_cursor)
  ↓
Postgres advances confirmed_flush_lsn
```

**Key insight**: The slot can only advance as fast as the slowest message store. Even if we send batch markers, `restart_wal_cursor!` is bounded by `min_unpersisted_wal_cursors` from all stores.

### Issue 1: Heartbeat Verification Fails

**Location**: `lib/sequin/runtime/slot_processor_server.ex:454-494`

**Flow**:
1. `verify_heartbeat/1` checks `message_received_since_last_heartbeat` (line 477)
2. This flag is only set to `true` in `flush_messages` when non-heartbeat messages exist (line 548-554)
3. No publication messages → no batches → flag stays `false`
4. After timeout → `:stale_connection` error → processor stops

**Additional check**: Line 471-473 compares `heartbeat_emitted_lsn` vs `last_flushed_high_watermark`. If high watermark never advances, this check can also fail with `:lsn_advanced` error.

### Issue 2: High Watermark Never Advances Downstream

**Location**: `lib/sequin/runtime/slot_producer/slot_producer.ex:308-312`

**Flow**:
1. `handle_info(:flush_batch, %{last_dispatched_wal_cursor: nil})` skips the flush
2. No batch marker sent → `last_flushed_high_watermark` never updates
3. `restart_wal_cursor!` queries `SlotMessageStore.min_unpersisted_wal_cursors/2`
4. With no consumers: returns `last_flushed_high_watermark` (nil or stale)
5. With consumers: returns nil because stores haven't received watermarks
6. SlotProducer ACKs with stale/nil cursor → Postgres doesn't release WAL

**Nuance on WAL retention**: Postgres retention is bounded by `confirmed_flush_lsn` and `restart_lsn`. Sequin updates `restart_wal_cursor` on a timer (every 5s via `:update_restart_wal_cursor`). The failure is that the cursor value itself can't advance because the high watermark never propagates downstream.

---

## Solution: Keepalive-Driven Batch Markers with Downstream Bounds

### Core Principle

**The mechanism is batch markers, not direct cursor advancement.**

To advance the slot using keepalive `wal_end`:
1. Emit a batch marker with keepalive-derived high watermark
2. Let the batch marker flow through SlotProcessorServer
3. SlotProcessorServer updates `last_flushed_high_watermark` and notifies stores
4. Stores persist the watermark
5. `restart_wal_cursor!` picks up the new floor from stores
6. SlotProducer ACKs to Postgres

This maintains the existing invariant: **restart_cursor is always bounded by what stores have persisted**.

### Why Keepalive `wal_end` Requires Careful Handling

The keepalive's `wal_end` is the server's current WAL **write** position, not necessarily:
- The last decoded position
- The last flushed position
- A position we've fully processed

**Risks of naive usage**:
- `wal_end` may be ahead of decoded messages sitting in our pipeline
- ACKing `wal_end` when we have in-flight messages = data loss on crash
- ACKing `wal_end` without downstream persistence = losing track of what stores have

### High Watermark Merge Rule

When emitting a batch marker, compute `high_watermark` as:

```elixir
high_watermark = cond do
  # Case 1: Have dispatched messages - use dispatched cursor
  # (normal path, keepalive doesn't help here)
  not is_nil(last_dispatched_wal_cursor) ->
    last_dispatched_wal_cursor

  # Case 2: No dispatched messages, but have keepalive - use keepalive
  # (keepalive-driven advancement)
  not is_nil(last_keepalive_wal_end) ->
    %{commit_lsn: last_keepalive_wal_end, commit_idx: 0}

  # Case 3: Nothing to advance with
  true ->
    nil  # Skip flush
end
```

**After first dispatch**: Once we've dispatched real messages, subsequent flushes use `last_dispatched_wal_cursor`. The keepalive path is for the "no publication messages at all" scenario.

**Post-dispatch keepalive advancement**: If we want keepalives to help even after dispatching (e.g., long gap between publication messages), we need:

```elixir
# For the normal flush path (when last_dispatched_wal_cursor is set)
# Consider using max(last_dispatched, keepalive) IF:
#   - last_dispatched has already been flushed (batch marker sent)
#   - keepalive is newer

high_watermark =
  if already_flushed?(last_dispatched_wal_cursor) and
     last_keepalive_wal_end > last_dispatched_wal_cursor.commit_lsn do
    %{commit_lsn: last_keepalive_wal_end, commit_idx: 0}
  else
    last_dispatched_wal_cursor
  end
```

This allows keepalive to advance the watermark during gaps between publication messages.

### Conditions for Keepalive-Driven Batch Markers

Emit a keepalive-driven batch marker ONLY when ALL of these are true:

1. **No dispatched messages pending flush**: `last_dispatched_wal_cursor` is nil
   - If we have dispatched messages, use normal flush path

2. **No accumulated messages**: `accumulated_messages.count == 0`
   - Respects demand/backpressure - don't skip queued messages

3. **No pending backfill watermarks**: `backfill_watermark_messages` is empty (in SlotProcessorServer)
   - Backfill watermarks are special logical messages that move the high watermark
   - Don't advance past them; let them flow through normally

4. **Keepalive is newer than last batch marker**:
   `last_keepalive_wal_end > last_batch_marker.high_watermark_wal_cursor.commit_lsn`
   - Avoid regression

5. **Keepalive received**: `last_keepalive_wal_end` is not nil

### Downstream Persistence is Still the Gatekeeper

**Critical**: Emitting a keepalive-driven batch marker does NOT immediately advance the restart cursor.

The flow is:
1. SlotProducer emits batch marker with keepalive cursor
2. SlotProcessorServer receives it, sets `last_flushed_high_watermark`
3. SlotProcessorServer calls `put_high_watermark_wal_cursor` on message handler
4. Message stores receive and persist the watermark
5. ONLY THEN does `restart_wal_cursor!` return the new value
6. ONLY THEN does SlotProducer ACK to Postgres

**When consumers exist**: The restart cursor is `min(store cursors)`. If stores haven't persisted the keepalive-driven watermark yet, restart cursor doesn't advance. This is correct - we wait for downstream confirmation.

**When no consumers exist**: `restart_wal_cursor!` returns `last_flushed_high_watermark` directly. This is safe because there are no messages to lose.

### Heartbeat Activity Flag

**Explicit requirement**: Set `message_received_since_last_heartbeat: true` on ANY successful batch flush, including keepalive-driven batches with zero messages.

The current code only sets this flag when `non_heartbeat_message?` is true. We must change this to set it unconditionally on flush success.

**Rationale**: A keepalive-driven batch marker proves:
1. SlotProducer is receiving keepalives (connection alive)
2. The pipeline is functioning (batch flowed through)
3. There's simply no publication traffic (not a stale connection)

---

## Implementation Plan

### Change 1: Track Keepalive WAL End in SlotProducer

**File**: `lib/sequin/runtime/slot_producer/slot_producer.ex`

```elixir
# Add to State struct (around line 126)
field :last_keepalive_wal_end, nil | integer()

# Update in handle_data(?k, ...) around line 498
defp handle_data(?k, <<?k, wal_end::64, clock::64, reply_requested>>, %State{} = state) do
  diff_ms = Sequin.Time.microseconds_since_2000_to_ms_since_now(clock)
  log = "Received keepalive message for slot (reply_requested=#{reply_requested}) (clock_diff=#{diff_ms}ms)"
  log_meta = [clock: clock, wal_end: wal_end, diff_ms: diff_ms]

  if reply_requested == 1 do
    Logger.info(log, log_meta)
  else
    Logger.debug(log, log_meta)
  end

  {:ok, %{state | last_keepalive_wal_end: wal_end}}
end
```

### Change 2: Keepalive-Driven Batch Marker Emission

**File**: `lib/sequin/runtime/slot_producer/slot_producer.ex`

Replace lines 308-312:

```elixir
def handle_info(:flush_batch, %State{last_dispatched_wal_cursor: nil} = state) do
  cond do
    # Guard 1: Have accumulated messages waiting for demand - can't skip them
    state.accumulated_messages.count > 0 ->
      Logger.debug("[SlotProducer] Skipping keepalive flush, have #{state.accumulated_messages.count} accumulated messages")
      {:noreply, [], %{state | batch_flush_timer: nil}}

    # Guard 2: No keepalive received yet - nothing to advance to
    is_nil(state.last_keepalive_wal_end) ->
      Logger.debug("[SlotProducer] Skipping flush, no keepalive received yet")
      {:noreply, [], %{state | batch_flush_timer: nil}}

    # Guard 3: Keepalive not newer than last batch marker (avoid regression)
    not is_nil(state.last_batch_marker) and
        state.last_keepalive_wal_end <= state.last_batch_marker.high_watermark_wal_cursor.commit_lsn ->
      Logger.debug("[SlotProducer] Skipping keepalive flush, not newer than last batch marker",
        keepalive_wal_end: state.last_keepalive_wal_end,
        last_batch_marker_lsn: state.last_batch_marker.high_watermark_wal_cursor.commit_lsn
      )
      {:noreply, [], %{state | batch_flush_timer: nil}}

    # All guards pass: emit keepalive-driven batch marker
    true ->
      cursor = %{commit_lsn: state.last_keepalive_wal_end, commit_idx: 0}

      Logger.info("[SlotProducer] Emitting keepalive-driven batch marker",
        keepalive_wal_end: state.last_keepalive_wal_end,
        batch_idx: state.batch_idx
      )

      batch_marker = %BatchMarker{
        high_watermark_wal_cursor: cursor,
        idx: state.batch_idx
      }

      Enum.each(state.consumers, fn consumer ->
        state.consumer_mod.handle_batch_marker(consumer, batch_marker)
      end)

      state = %{
        state
        | batch_idx: state.batch_idx + 1,
          last_batch_marker: batch_marker,
          batch_flush_timer: nil
      }

      {:noreply, [], state}
  end
end
```

**Note**: We do NOT set `last_dispatched_wal_cursor` because no messages were dispatched. The batch marker flows downstream to advance watermarks.

### Change 3: Backfill Watermark Guard in SlotProcessorServer

**File**: `lib/sequin/runtime/slot_processor_server.ex`

The backfill guard happens naturally: if `backfill_watermark_messages` is non-empty in state, the batch contains backfill messages that will be processed. We don't need a special guard in SlotProducer because:
- Backfill watermarks are logical messages that flow through the normal pipeline
- They're handled in `fold_message/2` and update state
- The batch high watermark from SlotProducer doesn't skip them

However, we should ensure keepalive-driven batches don't interfere. Add a check in `flush_messages`:

```elixir
# In flush_messages/2, after processing batch
# If this was a keepalive-driven batch (no real messages) AND we have pending backfill watermarks,
# don't advance last_flushed_high_watermark past them

# Actually, this is handled naturally because:
# 1. Keepalive batch has high_watermark = keepalive_wal_end
# 2. If backfill watermarks exist with lower LSNs, they came in earlier batches
# 3. Backfill watermarks advance the high watermark when they're flushed
# 4. The keepalive batch marker just advances to keepalive_wal_end

# The invariant we need: don't emit keepalive batch marker if there are
# accumulated backfill watermark MESSAGES in SlotProducer that haven't been dispatched.
# But backfill watermarks are logical messages (?M type) which ARE accumulated and dispatched.
# So the accumulated_messages.count > 0 guard already covers this.
```

**Conclusion**: The existing guards (accumulated_messages.count > 0) already prevent skipping backfill watermarks. No additional guard needed, but document this interaction.

### Change 4: Mark Activity on ALL Batch Flushes

**File**: `lib/sequin/runtime/slot_processor_server.ex`

In `flush_messages/2`, change from conditional to unconditional flag setting:

```elixir
# Around line 541-557
# BEFORE:
non_heartbeat_message? =
  Enum.any?(
    batch.messages,
    &(not match?(%Message{message: %LogicalMessage{prefix: "sequin.heartbeat" <> _rest}}, &1))
  )

state =
  if non_heartbeat_message? do
    Health.put_event(
      state.replication_slot,
      %Event{slug: :replication_message_processed, status: :success}
    )

    %{state | message_received_since_last_heartbeat: true}
  else
    state
  end

# AFTER:
non_heartbeat_message? =
  Enum.any?(
    batch.messages,
    &(not match?(%Message{message: %LogicalMessage{prefix: "sequin.heartbeat" <> _rest}}, &1))
  )

# Health event only for non-heartbeat messages (existing behavior)
if non_heartbeat_message? do
  Health.put_event(
    state.replication_slot,
    %Event{slug: :replication_message_processed, status: :success}
  )
end

# ALWAYS mark activity on any successful batch flush
# This includes keepalive-driven batches with zero messages
# Proves connection is alive even without publication traffic
state = %{state | message_received_since_last_heartbeat: true}
```

### Change 5: Ensure restart_wal_cursor! Handles Keepalive Watermarks

**File**: `lib/sequin/runtime/slot_processor_server.ex`

The existing logic in `restart_wal_cursor!/1` is correct:
- With consumers: returns `min(store cursors)` - waits for store confirmation
- Without consumers: returns `last_flushed_high_watermark` - safe, nothing to lose

No code change needed, but verify behavior:
1. Keepalive batch marker sets `last_flushed_high_watermark`
2. `put_high_watermark_wal_cursor` propagates to stores
3. Stores persist (or immediately ack if no messages)
4. `min_unpersisted_wal_cursors` returns the new floor
5. `restart_wal_cursor!` returns it
6. Slot advances

---

## Test Plan

### Test 1: Heavy Off-Publication WAL - Slot Advances

```elixir
test "slot advances when receiving only off-publication WAL" do
  # Setup: Create slot with publication on table A, consumer attached
  # Action: Insert 10k rows into table B (not in publication)
  # Assert:
  #   - SlotProducer logs "Emitting keepalive-driven batch marker"
  #   - last_flushed_high_watermark advances in SlotProcessorServer
  #   - restart_wal_cursor advances (query via SlotProcessorServer.restart_wal_cursor/1)
  #   - Postgres confirmed_flush_lsn advances (check pg_replication_slots)
  #   - No :stale_connection errors
end
```

### Test 2: Mixed Traffic - No Data Loss

```elixir
test "no data loss when publication messages arrive after keepalive advancement" do
  # Setup: Create slot, consumer on table A
  # Action:
  #   1. Insert 1000 rows into table B (off-publication) - triggers keepalive advancement
  #   2. Wait for keepalive batch marker to flush
  #   3. Insert 100 rows into table A (in publication)
  # Assert:
  #   - All 100 table A messages delivered to consumer
  #   - No gaps in delivery (check sequence/ids)
  #   - Consumer ack count matches inserted rows
end
```

### Test 3: Heartbeat Verification Passes During Flood

```elixir
test "heartbeat verification passes during off-publication flood" do
  # Setup: Create slot with short heartbeat timeout (e.g., 30s for test)
  # Action: Flood with off-publication WAL for 2 minutes
  # Assert:
  #   - No :stale_connection errors in logs
  #   - SlotProcessorServer stays alive (process check)
  #   - message_received_since_last_heartbeat is true after batch flushes
end
```

### Test 4: Backpressure Respected

```elixir
test "keepalive advancement respects accumulated messages" do
  # Setup: Create slot with consumer, configure low demand or slow consumer
  # Action:
  #   1. Insert into publication table (messages accumulate due to backpressure)
  #   2. Receive keepalives with higher wal_end
  # Assert:
  #   - Log shows "Skipping keepalive flush, have N accumulated messages"
  #   - accumulated_messages.count > 0 blocks keepalive advancement
  #   - Messages delivered in order when demand restored
  #   - No messages skipped
end
```

### Test 5: Downstream Persistence Bounds Advancement

```elixir
test "restart cursor bounded by store persistence" do
  # Setup: Create slot with consumer, mock slow store persistence
  # Action:
  #   1. Trigger keepalive-driven batch marker
  #   2. Query restart_wal_cursor BEFORE stores persist
  #   3. Allow stores to persist
  #   4. Query restart_wal_cursor AFTER stores persist
  # Assert:
  #   - Before persistence: restart_wal_cursor is nil or old value
  #   - After persistence: restart_wal_cursor equals keepalive-driven watermark
end
```

### Test 6: Keepalive + Previous Dispatch - No Regression

```elixir
test "high watermark uses max of dispatched and keepalive, no regression" do
  # Setup: Create slot with consumer on table A
  # Action:
  #   1. Insert into table A → dispatch → flush batch marker (e.g., LSN 1000)
  #   2. Long pause (no publication messages)
  #   3. Insert into table B (off-publication) → keepalive advances to LSN 2000
  #   4. Trigger flush
  # Assert:
  #   - If implementing post-dispatch keepalive advancement:
  #     - New batch marker has high_watermark LSN 2000
  #   - If NOT implementing (current plan):
  #     - Keepalive path only used when last_dispatched_wal_cursor is nil
  #     - After first dispatch, normal flush path continues
  #   - Either way: no regression (watermark never goes backward)
  #   - No data loss
end
```

---

## Work Items

### Completed

- [x] Make heartbeat intervals configurable via env vars
  - `SLOT_PROCESSOR_MAX_HEARTBEAT_EMISSION_INTERVAL_MIN` (default: 5)
  - `SLOT_PROCESSOR_MAX_HEARTBEAT_RECEIVE_TIMEOUT_MIN` (default: 10)
  - Files changed: `config_parser.ex`, `runtime.exs`, `slot_processor_server.ex`

### TODO

- [ ] **Change 1**: Add `last_keepalive_wal_end` to SlotProducer state
- [ ] **Change 2**: Implement keepalive-driven batch marker emission with guards
- [ ] **Change 3**: Document backfill watermark interaction (no code change needed)
- [ ] **Change 4**: Set `message_received_since_last_heartbeat: true` unconditionally on flush
- [ ] **Change 5**: Verify `restart_wal_cursor!` handles keepalive watermarks (no code change expected)
- [ ] **Test 1**: Heavy off-publication WAL - slot advances
- [ ] **Test 2**: Mixed traffic - no data loss
- [ ] **Test 3**: Heartbeat verification passes during flood
- [ ] **Test 4**: Backpressure respected
- [ ] **Test 5**: Downstream persistence bounds advancement
- [ ] **Test 6**: Keepalive + previous dispatch - no regression

---

## Key Files

| File | Purpose |
|------|---------|
| `lib/sequin/runtime/slot_processor_server.ex` | Heartbeat logic, flush handling, `restart_wal_cursor!` |
| `lib/sequin/runtime/slot_producer/slot_producer.ex` | WAL reception, message dispatch, batch markers |
| `lib/sequin/runtime/slot_message_store.ex` | Message persistence, `min_unpersisted_wal_cursors` |
| `lib/sequin/runtime/slot_producer/pipeline_defaults.ex` | Default callbacks |

## Key State Fields

### SlotProducer.State
- `last_commit_lsn` - LSN of last committed transaction (set even for non-publication txns)
- `last_dispatched_wal_cursor` - cursor of last dispatched MESSAGE (nil if no publication messages)
- `last_keepalive_wal_end` - **NEW** - wal_end from most recent keepalive
- `last_batch_marker` - last batch marker sent (for regression check)
- `accumulated_messages` - messages matching publication, waiting for demand

### SlotProcessorServer.State
- `message_received_since_last_heartbeat` - boolean, proves connection is alive
- `last_flushed_high_watermark` - wal_cursor from last successful flush
- `heartbeat_emitted_at` - timestamp of last heartbeat emission
- `heartbeat_emitted_lsn` - LSN when heartbeat was emitted
- `backfill_watermark_messages` - pending backfill watermarks (handled in fold_message)

### SlotMessageStore
- Tracks `min_unpersisted_wal_cursors` - the floor for safe ACK

---

## Invariants

1. **Batch markers are the mechanism**: Keepalive advancement happens by emitting batch markers, not by directly setting cursors. The downstream pipeline (stores) must persist before restart_cursor advances.

2. **Never ACK past downstream persistence**: `restart_wal_cursor <= min(store cursors)`. The keepalive batch marker flows through stores; we wait for their confirmation.

3. **Never skip accumulated messages**: If `accumulated_messages.count > 0`, don't emit keepalive batch marker. This includes backfill watermark messages (they're accumulated like any other message).

4. **Never regress cursors**: Keepalive batch marker high_watermark must be > last batch marker's high_watermark.

5. **Activity = batch flushed**: ANY successful batch flush (including keepalive-driven with zero messages) sets `message_received_since_last_heartbeat: true`.

6. **Keepalive path is for "no publication traffic" scenario**: Once we've dispatched real messages, the keepalive path (Change 2) doesn't apply. Future enhancement could merge `max(dispatched, keepalive)` for gaps between publication messages.

7. **Prefer correctness over throughput**: When in doubt, skip the keepalive flush and wait for real messages or the next keepalive.
