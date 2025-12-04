# Replication Slot Fix - Analysis & Plan

## Problem Statement

When large amounts of data are pushed to tables NOT in the Sequin publication, the replication slot gets stuck in a death spiral:
1. Heartbeat messages can't arrive within 10 minutes (now configurable)
2. LSN can't advance because no messages are being flushed

## Root Cause Analysis

### Issue 1: Heartbeat Verification Fails After 10 Minutes

**Location**: `lib/sequin/runtime/slot_processor_server.ex:454-494`

**Flow**:
1. `verify_heartbeat/1` checks `message_received_since_last_heartbeat` (line 477)
2. This flag is only set to `true` in `flush_messages` (line 554)
3. `flush_messages` is only called when batches with publication-matching messages arrive
4. When all WAL goes to non-publication tables → no batches → flag stays `false`
5. After 10 minutes → `:stale_connection` error → processor stops

**Key code path**:
```
SlotProducer receives WAL → filters by publication → no matches → no dispatch
→ no batch to SlotProcessorServer → flush_messages never called
→ message_received_since_last_heartbeat stays false
→ verify_heartbeat returns :stale_connection after 10 min
```

### Issue 2: LSN Cannot Advance

**Location**: `lib/sequin/runtime/slot_producer/slot_producer.ex:308-312` and `lib/sequin/runtime/slot_processor_server.ex:694-747`

**Flow**:
1. `restart_wal_cursor!` returns `last_flushed_high_watermark` (line 700)
2. `last_flushed_high_watermark` only updates in `flush_messages` (line 605)
3. Flush is skipped when `last_dispatched_wal_cursor` is nil (line 308-312)
4. No publication messages → no dispatch → cursor stays nil → flush skipped
5. High watermark never advances → slot never ACKs to Postgres → WAL retained

**Key code path**:
```
SlotProducer.handle_info(:flush_batch, %{last_dispatched_wal_cursor: nil})
→ "Skipping flush_batch, no messages dispatched yet" (line 309)
→ batch marker never sent → high watermark never advances
→ restart_wal_cursor returns nil → slot doesn't ACK → Postgres retains WAL
```

## Work Items

### Completed

- [x] Make heartbeat intervals configurable via env vars
  - `SLOT_PROCESSOR_MAX_HEARTBEAT_EMISSION_INTERVAL_MIN` (default: 5)
  - `SLOT_PROCESSOR_MAX_HEARTBEAT_RECEIVE_TIMEOUT_MIN` (default: 10)
  - Files changed: `config_parser.ex`, `runtime.exs`, `slot_processor_server.ex`

### TODO

- [ ] **Fix 1**: Track WAL activity independently of message dispatch
  - Add `last_wal_activity_at` or similar to SlotProcessorServer state
  - Update this timestamp whenever SlotProducer is actively receiving WAL
  - Use this in `verify_heartbeat` to know the connection is alive even without publication messages
  - This prevents false `:stale_connection` errors during massive non-publication traffic

- [ ] **Fix 2**: Allow LSN advancement for empty transactions
  - When transactions commit but contain no publication messages, still advance the high watermark
  - Options:
    a. Send batch markers even when no messages were dispatched (modify line 308-312)
    b. Track `last_commit_lsn` separately and use it for slot advancement
    c. Use keepalive-driven advancement when no messages are flowing
  - This allows the slot to ACK progress and release WAL

## Key Files

| File | Purpose |
|------|---------|
| `lib/sequin/runtime/slot_processor_server.ex` | Heartbeat logic, flush handling, LSN tracking |
| `lib/sequin/runtime/slot_producer/slot_producer.ex` | WAL reception, message dispatch, batch markers |
| `lib/sequin/runtime/slot_producer/pipeline_defaults.ex` | Default callbacks including `restart_wal_cursor` |
| `lib/sequin/runtime/message_handler.ex` | Message filtering by table_oid |

## Key State Fields

### SlotProcessorServer.State
- `message_received_since_last_heartbeat` - boolean, set true when non-heartbeat messages flushed
- `last_flushed_high_watermark` - wal_cursor, updated after successful flush
- `heartbeat_emitted_at` - timestamp of last heartbeat emission
- `heartbeat_emitted_lsn` - LSN when heartbeat was emitted

### SlotProducer.State
- `last_commit_lsn` - LSN of last committed transaction (set even for non-publication txns)
- `last_dispatched_wal_cursor` - cursor of last dispatched message (nil if no publication messages)
- `restart_wal_cursor` - cursor used for ACKing to Postgres

## Notes

The fundamental issue is that Sequin conflates "receiving WAL" with "having publication-matching messages". These need to be decoupled:
1. Connection health should be based on WAL activity, not message dispatch
2. Slot advancement should happen based on committed transactions, not just dispatched messages
