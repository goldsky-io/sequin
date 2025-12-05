# Replication Slot Lag Investigation - 2025-12-04

## Summary

Multiple replication slots experienced lag due to a process crash loop in SlotProcessorServer. The root cause is a **state management bug** where sink consumer monitoring isn't properly initialized/maintained on restart.

## Affected Slots

1. `6b86fba4-5be0-4948-b304-325ba13fa59e` (DB: `38c80993-033a-413c-a1a1-de7a5c5cac51`) - auto-recovered after ~80s
2. `312991f0-7130-4c41-8dd3-1861c36e78f2` (DB: `3f469086-b59a-47dc-879c-0f157f7e911c`) - required service restart

## Root Cause

### The Error

```
** (Sequin.Error.InvariantError) Sink consumer IDs do not match monitored sink consumer IDs.
Sink consumers: ["c1bd54f7-08e5-4472-b54c-853cad845bb9", "2340764a-74e8-474b-92f0-b07979625eb3", "c4a3ad8a-9f45-4962-af58-175b84da5125"].
Monitored: []
```

Location: `lib/sequin/runtime/slot_processor_server.ex:749`

### Crash Loop Sequence

1. **SlotProcessorServer** crashes due to monitoring mismatch invariant
2. **ReorderBuffer** tries to send batches via `GenServer.call` to SlotProcessorServer
3. Call fails: `(EXIT) no process: the process is not alive`
4. ReorderBuffer crashes
5. Supervisor restarts both processes
6. SlotProcessorServer hits same invariant on restart → crash again
7. WAL cursor can't advance → slot lags

### Secondary Issues Observed

- **Heartbeat nil error**: `ArithmeticError: bad argument in arithmetic expression` in `Time.after_min_ago?/2` - heartbeat timestamp uninitialized
- **Runtime Starter timeout**: `Task.Supervised.stream(30000)` timeout during initialization
- **DBConnection errors**: Pool connections being closed

## Why Recovery Sometimes Works

The supervisor eventually restarts all components in the correct order. When SlotProcessorServer successfully initializes before ReorderBuffer tries to send batches, the pipeline recovers. This took ~80 seconds for the first slot.

## Recommended Fixes

1. **Fix monitoring initialization**: Ensure sink consumers are registered with monitoring before SlotProcessorServer processes batches. The invariant check at line 749 should either:
   - Be relaxed during startup/restart
   - Have monitoring setup occur before the check runs

2. **Add circuit breaker**: ReorderBuffer should back off when SlotProcessorServer is unavailable instead of crash-looping

3. **Fix heartbeat initialization**: Ensure heartbeat timestamp is never nil

4. **Improve supervision strategy**: Consider `rest_for_one` or explicit startup ordering to ensure dependencies start in correct order

## Resolution

Full ECS service restart resolves the issue by reinitializing all processes cleanly.
