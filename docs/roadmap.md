# Bitta: Roadmap

The goal is a working D flip-flop. Everything before that is infrastructure. Everything after is future work.

Phases are sequential. Each phase ends with a concrete demo—something you can run and observe. No phase is "done" until its tests pass and its demo works.

---

## Phase 0 — Core Types

**What gets built:**
- `Signal` enum (LOW, HIGH, FLOATING, UNRESOLVED, CONFLICT, UNKNOWN)
- `Strength` enum (STRONG, WEAK)
- `DriveIntent` dataclass
- `resolve()` — the node resolution algorithm
- `Node` (driver dict, resolution, no queue yet)
- `EventQueue` (schedule, cancel, pop, deterministic ordering)

**Done when:**
- `resolve()` passes tests for all input combinations (see design.md resolution algorithm)
- `Node.set_driver` / `remove_driver` updates the driver dict and re-resolves
- `EventQueue` processes events in time order; same-time events are deterministic; cancelled events are skipped

**Demo:** unit tests only—no circuit yet.

**Risks:**
- Lambda capture bugs in scheduled actions (see design.md Trap 1)
- Off-by-one in same-time ordering

---

## Phase 1 — Node Inertia

**What gets built:**
- `Node` wired to `EventQueue`: `_recompute`, `_commit`, `pending_transition_event_id`, `generation`
- Inertia: state changes are deferred; rapid changes cancel and reschedule

**Done when:**
- A node driven HIGH takes exactly `inertia_delay` ticks to commit
- A drive that changes back before the transition fires cancels the pending transition
- `generation` increments once per committed state change, not per recompute

**Demo:** drive a node HIGH, remove the drive before inertia fires → node stays FLOATING.

---

## Phase 2 — Primitives and Simulator

**What gets built:**
- `Switch` (NMOS and PMOS, control/input/output, evaluate on change)
- `ConstantSource` (VCC, GND, pull-up, pull-down)
- `ScheduledSource` (timed signal injection)
- `Circuit` (node/switch/connection/source registry)
- `Simulator.run()` (event loop, quiescence and time-limit termination)

**Done when:**
- VCC attached to a node drives it to HIGH after inertia settles
- An NMOS switch with control=HIGH passes a drive from input to output
- An NMOS switch with control=LOW blocks the drive
- Undefined control (FLOATING) → switch open

**Demo:** two nodes, one driven HIGH via VCC, connected through a switch. Toggle the switch control and watch the output node change state.

---

## Phase 3 — Connection and First Gate

**What gets built:**
- `Connection` (unidirectional, propagation delay, propagates resolved state as STRONG)
- NOT gate (NMOS switch + pull-up)
- NAND gate (two NMOS switches in series + pull-up)

**Done when:**
- A connection delivers a STRONG drive to the target node after `propagation_delay` ticks
- Removing the source drive removes the target drive after delay
- NOT gate: input HIGH → output LOW, input LOW → output HIGH (after settling)
- NAND gate: truth table correct for all four input combinations

**Demo:** NAND gate driven by two `ScheduledSource` inputs cycling through all input combinations. Print output state after each input change settles.

---

## Phase 4 — Trace and Contracts

**What gets built:**
- `TraceStore` and `NodeTrace` (record every state commit)
- Trace query helpers: `state_at`, `transitions`, `stable_for`, `first_time`, `last_rising_edge`
- `Contract` protocol and `ContractResult`
- `SimulationResult` (wraps end time, traces, termination reason)
- `check_contracts()` runner

**Done when:**
- Every node state change appears in its trace with correct time and generation
- `state_at(trace, t)` returns the correct state for arbitrary `t`
- A NAND truth-table contract passes against a NAND simulation
- A deliberately broken circuit (wrong wiring) causes a contract to fail with a readable message

**Demo:** NAND gate simulation. Print the trace for the output node. Run the truth-table contract and print pass/fail.

---

## Phase 5 — Component System

**What gets built:**
- `ComponentInstance` dataclass (terminal nodes, internal nodes, sub-instances)
- Convention: component definitions are plain functions `(Circuit, dict[str, NodeId]) → ComponentInstance`
- `CircuitBuilder` helpers if needed to reduce boilerplate

**Done when:**
- `nand_gate()` definition can be instantiated twice into the same circuit without any shared internal nodes
- An SR latch can be built by composing two NAND instances (cross-coupled)
- Component internals are invisible to the parent—only terminal nodes are referenced externally

**Demo:** instantiate two NAND gates, wire them as SR latch manually (before the SR latch definition exists). Drive S and R, observe Q.

---

## Phase 6 — SR Latch and D Latch

**What gets built:**
- `sr_latch()` component definition
- `d_latch()` component definition (SR latch + steering gates)
- Contracts for both

**Done when:**
- SR latch holds state after S is released
- SR latch resets after R is asserted
- SR latch invalid state (both inputs LOW) → both outputs HIGH (defined NAND behavior)
- D latch: when CLK=HIGH, Q follows D; when CLK=LOW, Q holds last value
- Both contracts pass

**Demo:** SR latch: set, release S, assert R. Print Q trace showing hold then reset. D latch: toggle D while CLK=HIGH, then freeze CLK=LOW and toggle D again—Q should not change.

---

## Phase 7 — D Flip-Flop (MVP)

**What gets built:**
- `d_flip_flop()` component definition (master-slave D latches)
- D flip-flop contract: Q captures D on rising CLK edge, holds until next rising edge

**Done when:**
- Q changes only on rising CLK edge, not on D changes
- Q reflects the value of D at the moment of the rising edge
- Contract passes for a simulation with multiple clock cycles and D changes between edges
- Contract correctly fails when timing is violated (D changes during CLK transition)

**Demo:** 10-cycle simulation. D alternates every 3 ticks. CLK period = 10 ticks. Print Q trace showing Q is stable between edges and captures D correctly.

**This is the MVP. Stop here and declare success.**

---

## Future Work (Unscheduled)

These are not blocked, but are not planned until Phase 7 is complete and stable.

### F1 — Register
N-bit register from N D flip-flops. Write-enable input. Contracts: all bits capture on clock edge, all bits hold otherwise.

### F2 — Multiplexer
2:1 and N:1 MUX from NAND gates. Contracts: output matches selected input.

### F3 — Adder
Half-adder, full-adder, N-bit ripple-carry adder. Contracts: arithmetic correctness. Note: expect a glitch cascade on the carry chain before settling—this is correct behavior, not a bug.

### F4 — ALU
Add, subtract (two's complement), AND, OR, compare. Contracts: output correct after settling.

### F5 — Register File
N registers with address-decoded read/write ports.

### F6 — CPU
Program counter, instruction decoder, control unit, data path. ISA TBD (minimal: load, store, add, branch).

---

## Deferred Questions (from concept.md open questions)

These don't block any current phase but should be answered before Future Work begins.

| Question | When it matters |
|---|---|
| PMOS switches | F3 (CMOS gates avoid pull-ups; NMOS-only works but is less realistic) |
| Noise injection for metastability | Phase 6 (symmetric latch may need it) |
| Cycle detection at build time | Phase 5 (better error than stack overflow) |
| Generation rate guard | Phase 6 (cross-coupled latches can oscillate) |
