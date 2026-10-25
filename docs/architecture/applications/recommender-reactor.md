# Recommender reactor

Task 12.1 supplies `examples/recommender/reactor.bv`. A reactor node calls
`reactor_poll` once per sweep, consumes each slot's `reactor_events`, and advances
its saved connection state. The loopback fixture demonstrates the node entry;
HTTP lifecycle and application routing are implemented in server_loop.bv and
its server_io/server_api/server_live modules (see recommender-server.md).

`reactor_open(port, capacity)` owns a nonblocking listener and two allocations.
A negative listener is a setup failure carrying -errno; no allocations survive
that failure. Capacity is 1..65535, port is 0..65535 (zero selects an ephemeral
port). `reactor_close` releases all active peers, listener and allocations.
The Reactor value aliases owned storage: do not close it twice or use it after
close. Only the reactor thread may mutate its table.

Linux x86_64 pollfd is eight bytes: signed i32 fd, i16 requested events,
i16 returned events, in host byte order. Record zero is the listener. Connection
slot s uses record s+1; unused records carry fd=-1 and no interest. Each stable
slot has sixteen 64-bit fields: fd (-1 when unused), authenticated account id,
upgraded flag, live owner id, parse byte count, owned input buffer pointer,
owned output buffer pointer, output sent offset, phase (reading=0, writing=1,
websocket=2), output length, input capacity, fragment pointer, fragment length,
fragment opcode, close-after-write flag and read-EOF flag. Initial identities and pointers are zero. Lifecycle code must keep
owned buffers distinct and update their pointers when allocations move.

`reactor_find` maps a live fd to its slot; never use a kernel fd as an array
index. `reactor_remove` closes the peer, frees its input/output buffers and clears
all identity/protocol state before allowing reuse. Removing an empty slot is
safe. Slot-taking functions require 0 <= slot < capacity.

`reactor_poll` returns the kernel's ready-record count or -errno (EINTR yields
zero, letting the next reactor firing retry). It accepts at most one peer per
sweep, explicitly sets that peer nonblocking, and exposes client revents without
discarding HUP/ERR data. Its return count includes the listener; an accepted peer
has no client readiness until the next sweep. At capacity listener interest is
disabled; release a slot to resume accepting. The table is configured per server,
with no hardcoded dependence on small descriptor values. This is bounded fair
scheduling, not a throughput measurement or a 1000-channel performance claim.

Native gate: compile `tests/fixtures/recommender/reactor_gate.bv` and run it.
It binds an ephemeral port, accepts multiple loopback peers, checks data-readiness
isolation, full capacity, cleared ownership on reuse, repeated empty removal and
invalid configuration. No database or external listener is required.
