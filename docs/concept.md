# Bitta: Concept Design Document

## Overview

**Bitta** is an event-driven digital circuit simulator built from minimal primitives that approximate real electrical behavior without modeling full analog physics.

The core idea:

> **Digital logic is not assumed—it emerges from interactions between simple components over time.**

The long-term goal is to simulate a CPU, built up from the simplest possible pieces. The path runs:

```
primitives → logic gates → latches → registers → ALU → CPU
```

Bitta separates three concerns that must never bleed into each other:

| Layer | Question | Implementation |
|---|---|---|
| **Physics** | What happened? | Event queue, nodes, connections |
| **Observation** | What was recorded? | Trace history |
| **Judgment** | Was it valid? | Contracts |

---

## Design Principles

### 1. Physics is Dumb and Honest
The simulator does not enforce correctness. It only answers: *what happened?* Conflicts, instability, and garbage propagation are all valid simulation outcomes.

### 2. Contracts are External and Post-Hoc
Correctness is evaluated by reading trace history after simulation. Contracts cannot influence physics.

### 3. Composition First
All behavior emerges from composing small primitives. There are no special cases for "logic gates" or "latches"—these are just circuits that happen to emerge from the primitives.

### 4. Time is Event-Based
No global tick. Events are scheduled at discrete timestamps and processed in order. Signals propagate with delay.

### 5. Deterministic, Seeded Execution
Simulation is fully deterministic given a seed. Randomness can be introduced deliberately to break symmetry (e.g. metastability resolution), but the seed controls everything.

### 6. Stability is a Design Constraint, Not a Guarantee
The simulator will happily run a circuit that oscillates forever. It is the circuit designer's responsibility to ensure delay parameters prevent zero-delay cycles.

---

## Core Concepts

### Nodes

A **node** is the fundamental unit of truth. It represents a wire segment—a point in the circuit that has a single electrical state at any moment.

```
Node:
  id
  current_state
  candidate_state
  pending_transition_event_id   # null if no transition is pending
  drivers                       # set of active DriveIntents
  inertia_delay                 # minimum time before state can change
  generation                    # monotonically incremented on each state change
```

`generation` is useful for detecting runaway oscillation (generation advancing much faster than simulation time) and for writing time-independent contracts ("Q was stable for N generations after CLK rose").

Nodes:
- Aggregate drive intents from all sources
- Resolve those intents to a candidate state
- Transition to the candidate state after `inertia_delay`

#### Node States

| State | Meaning |
|---|---|
| `LOW` | Logic zero |
| `HIGH` | Logic one |
| `FLOATING` | No drivers present |
| `UNRESOLVED` | Competing weak drivers with no dominant value |
| `CONFLICT` | Opposing strong drivers (electrical short) |
| `UNKNOWN` | Simulation error—should not appear in a valid circuit |

`UNKNOWN` exists as an explicit error sentinel. It arises only from simulator bugs or from an uninitialized node that a contract query touches before simulation begins. It should never appear as a result of normal resolution.

---

### Drive Intents

All influence on nodes is expressed as drive intents. Nothing else can change a node's state.

```
DriveIntent:
  source_id     # which component/primitive is driving
  value: HIGH | LOW
  strength: STRONG | WEAK
```

`source_id` enables diagnostics: when a node is in CONFLICT, you can identify which two sources are fighting.

| Strength | Physical meaning | Example |
|---|---|---|
| `STRONG` | Active driver | Transistor conducting, VCC, GND |
| `WEAK` | Passive bias | Pull-up resistor, pull-down resistor |

---

### Node Resolution

Node state is derived deterministically from its active drive intents. This runs every time the driver set changes.

#### Complete Resolution Algorithm

```
1. If no drive intents:
     → FLOATING

2. Partition intents by strength.

3. If any STRONG intents:
     a. If all STRONG intents are HIGH → HIGH
     b. If all STRONG intents are LOW  → LOW
     c. If STRONG HIGH and STRONG LOW both present → CONFLICT
   (WEAK intents are ignored when STRONG is present)

4. If only WEAK intents:
     a. If all WEAK intents are HIGH → HIGH
     b. If all WEAK intents are LOW  → LOW
     c. Mixed WEAK intents → UNRESOLVED
```

This produces a **candidate state**. The node does not immediately adopt it.

**Note on CONFLICT propagation:** A CONFLICT node does not propagate drive intents to connected nodes. Electrical damage is isolated to the shorted node. Connected nodes continue to see whatever other drives they have. This is conservative but keeps failures local and debuggable.

---

### Node Inertia

Nodes do not change instantly. This is the mechanism that enables glitch filtering, latch behavior, and realistic propagation.

```
on candidate state change:
  if pending_transition_event_id is not null:
    cancel that event
  if candidate != current:
    schedule new transition event at (now + inertia_delay)
    record its id in pending_transition_event_id
  else:
    pending_transition_event_id = null
```

When the transition event fires:
```
  current_state = candidate_state
  generation += 1
  pending_transition_event_id = null
  notify all connections
```

#### Stability Requirement

**Every cycle in the circuit must have total delay > 0.** A cycle with total delay = 0 (all connections have `propagation_delay = 0` and all nodes have `inertia_delay = 0`) will cause the simulator to loop forever.

Recommended defaults:
- `inertia_delay = 1` (in simulation time units) for all nodes
- `propagation_delay >= 1` for all connections

Setting both to zero is legal on non-cyclic paths but should be avoided in practice to keep behavior predictable.

---

### Connections (Wires)

A connection links two nodes with a propagation delay. Connections are **bidirectional**: drive intents flow from whichever node is actively driving toward the other.

```
Connection:
  node_a
  node_b
  propagation_delay
```

Behavior:
```
on node_a state change:
  schedule: apply node_a's drive intents to node_b at (now + propagation_delay)

on node_b state change:
  schedule: apply node_b's drive intents to node_a at (now + propagation_delay)
```

Connections do not have state. They are pure delay elements.

**Gotcha:** A connection does not copy state—it propagates drive intents. If node_a has `STRONG HIGH` and connects to node_b, node_b receives a `STRONG HIGH` drive intent from the connection, not a copy of node_a's state.

---

### Terminals

A terminal is the interface point between a component and the outside world.

```
Terminal:
  name
  internal_node
  external_node
```

A terminal behaves like a connection with zero (or configurable) propagation delay across the component boundary. It is bidirectional. Drive intents flow inward and outward.

Terminals give components identity: two terminals with the same internal topology but different names are different interfaces. This is what allows `Q` and `Q_bar` to be distinct outputs of a latch.

---

### Switch

The switch is the most important primitive. It is the transistor abstraction.

```
Switch:
  control:  Terminal   # gate
  input:    Terminal   # source
  output:   Terminal   # drain
  polarity: NMOS | PMOS
```

Behavior:
- **NMOS** (normal, active-high): when `control = HIGH`, the switch conducts—all drive intents on `input` are forwarded to `output`. When `control = LOW`, the switch is open—no intents forwarded.
- **PMOS** (active-low): when `control = LOW`, conducts. When `control = HIGH`, open.

When `control` is `FLOATING`, `UNRESOLVED`, or `CONFLICT`, the switch is **open** (conservative default). A transistor with an undefined gate voltage is assumed non-conducting. This prevents ambiguous control states from propagating garbage.

#### Why This Is Enough

With NMOS switches, VCC (STRONG HIGH), GND (STRONG LOW), and a pull-up (WEAK HIGH):

```
NOT gate:
  - input drives switch control
  - switch input connects to GND (STRONG LOW)
  - switch output connects to output node
  - pull-up provides WEAK HIGH on output node
  - when input HIGH: switch conducts, GND drives output LOW (STRONG beats WEAK)
  - when input LOW:  switch open, only pull-up remains, output HIGH
```

```
NAND gate:
  - two switches in series between output node and GND
  - pull-up on output node
  - conducts (output LOW) only when both inputs HIGH
```

PMOS switches enable CMOS gates (no pull-up needed, complementary topology). Starting with NMOS-only is fine; PMOS is an optional upgrade.

---

### Components

A component is a named subgraph with a defined interface.

```
Component:
  name
  internal_nodes:    [Node]
  internal_connections: [Connection]
  sub_components:    [Component]   # components can contain components
  terminals:         [Terminal]
```

Components:
- Encapsulate topology
- Can be instantiated multiple times
- Expose only terminals to the outside
- Internal nodes are invisible to the parent circuit

This is how complexity is managed. A D flip-flop is a component containing NAND gates. A register is a component containing D flip-flops. The simulator does not care about the hierarchy—it just sees nodes, connections, and drive intents.

#### Initial State

All internal nodes in a freshly instantiated component start as `FLOATING`. Components that require a known initial state (e.g. a latch that must start RESET) need an initialization event or a reset input that is asserted at `time = 0`.

---

### Signal Sources

Signal sources are external drivers that inject events into the simulation. They are the test bench.

```
SignalSource:
  target_node
  schedule: [(time, DriveIntent)]
```

Examples:
- `ConstantSource`: drives a fixed value forever (implements VCC and GND)
- `PulseSource`: drives HIGH for a duration, then LOW
- `SquareWaveSource`: alternates at a fixed period
- `ManualSource`: events injected by the test or user

Clocks are not special. A clock is a `SquareWaveSource` attached to a node. The simulation does not know or care that it is a clock.

**Important:** simulation time is not circuit time. Simulation time is an abstract counter. What matters is the *ratio* of delays: a clock period of 100 units with gate delays of 5 units is well-specified behavior.

---

### Event Queue

The event queue is the engine of the simulator.

```
Event:
  id
  time
  action: () -> ()
```

Rules:
- Events are processed in ascending time order
- At equal timestamps, events are processed in **arbitrary but deterministic order** (determined by insertion order or a stable sort key, not by random choice)
- Events may only schedule new events at `time >= now`
- Events may be cancelled by id (used by inertia)

**Gotcha: simultaneous events.** If two events at the same timestamp each affect the other's inputs, order matters. The current design resolves this by processing them in deterministic insertion order and recomputing node states after each. This means a simultaneous A→HIGH and B→LOW on nodes that drive each other will have a defined (if potentially surprising) outcome. This is acceptable: in real circuits, simultaneous transitions are a setup/hold violation and behavior is undefined anyway.

#### Termination

Simulation ends when:
1. The event queue is empty (quiescence), or
2. A user-specified time limit is reached, or
3. A contract with `halt_on_violation: true` detects a violation

---

### Observation (Trace)

The trace system is the bridge between physics and judgment. It is read-only with respect to simulation.

```
NodeTrace:
  node_id
  history: [(time, generation, state)]
```

Every state change is recorded. The trace system does not affect node behavior.

Contracts read traces. Test assertions read traces. Debugging reads traces. The simulator does not need to know why traces exist.

#### Trace Queries

Useful query primitives:
- `state_at(node, time)` — what was the state at a given time
- `last_transition(node, before: time)` — most recent change before a time
- `stable_for(node, duration)` — was the node stable for at least N time units
- `first_time(node, state)` — when did the node first reach a state

---

### Contracts

A contract describes what a component should do. It is evaluated against traces after simulation.

```
Contract:
  name
  assumptions: [TraceAssertion]   # preconditions on inputs
  guarantees:  [TraceAssertion]   # what must hold if assumptions are met
  halt_on_violation: bool
```

Example—D latch:
```
D latch contract:
  assume: D is stable for setup_time before CLK falls
  assume: D is stable for hold_time after CLK falls
  guarantee: Q matches D within propagation_time after CLK falls
```

Contracts can be conditional: if assumptions are not met, the contract does not fire. This lets you write "this component is correct when used correctly" without requiring the simulator to enforce correct usage.

**Contracts never affect physics.** They observe and report. A contract violation means "the designer made an error or the parameters are wrong"—not "the simulator should intervene."

#### Lemmas

A lemma is a reusable trace assertion that can be composed into contracts:

```
Lemma:
  name
  assertion: TraceAssertion
```

Example lemmas: `setup_hold_satisfied`, `no_glitch_wider_than(N)`, `transitions_within(N_of, event)`.

---

### Metastability (Emergent)

Metastability is not special-cased. It emerges from the interaction of:
- `UNRESOLVED` state on a node
- A feedback loop passing through that node
- Inertia that sustains the indecision

In a symmetric cross-coupled latch with identical timing, both Q and Q_bar can reach `UNRESOLVED` and stay there. Resolution requires a symmetry-breaking input:
- Asymmetric propagation delays (even by 1 time unit)
- An explicit reset/set pulse
- Seeded noise injection (the simulator's randomness mechanism)

**Noise injection:** When a node has been `UNRESOLVED` for longer than a configurable `noise_threshold`, the simulator can inject a random `WEAK` drive intent to break symmetry. The direction is determined by the simulation seed. This is the only place randomness enters the physics layer, and it is controlled and documented.

---

## Primitive Set

These eight primitives are the complete foundation. Everything else is a component built from them.

| Primitive | Behavior |
|---|---|
| `Node` | Holds state, aggregates drives |
| `Connection` | Bidirectional delay between nodes |
| `Terminal` | Component interface point |
| `Switch (NMOS)` | Conducts when control HIGH |
| `Switch (PMOS)` | Conducts when control LOW |
| `VCC` | Permanent `STRONG HIGH` source |
| `GND` | Permanent `STRONG LOW` source |
| `Pull-up` | Permanent `WEAK HIGH` source |
| `Pull-down` | Permanent `WEAK LOW` source |

`VCC` and `GND` are implemented as `ConstantSource` signal sources, not special node types. `Pull-up` and `Pull-down` are drive intents, not separate node types.

---

## Path to CPU

The design is layered. Each level is fully testable before the next is built.

```
Level 0: Primitives
  Node, Connection, Terminal, Switch, VCC, GND, Pull-up, Pull-down
  Test: a single switch correctly gates a signal

Level 1: Logic gates (from primitives)
  NOT, NAND, NOR, AND, OR, XOR
  Test: truth tables verified via contracts

Level 2: Memory elements (from gates + feedback + inertia)
  SR latch, D latch, D flip-flop, T flip-flop
  Test: hold behavior, setup/hold violations, metastability

Level 3: Functional units (from flip-flops + combinational logic)
  Register (N-bit), Counter, Multiplexer, Half-adder, Full-adder, Ripple-carry adder
  Test: arithmetic correctness, timing margins

Level 4: CPU subsystems (from functional units)
  ALU (add, subtract, AND, OR, compare)
  Register file (N registers with read/write ports)
  Program counter (register + increment)
  Instruction decoder (combinational)
  Control unit (state machine)
  Test: each subsystem independently

Level 5: CPU
  Integrate subsystems
  Define ISA (instruction set architecture)
  Test: execute small programs, verify register state
```

The first milestone worth celebrating is Level 2: when a cross-coupled NAND latch holds state. That's when emergence becomes visible.

The first time the system becomes complex enough to surprise you is Level 3: a ripple-carry adder produces a glitch cascade on its carry chain before settling. Inertia and propagation delay interact in non-obvious ways. This is expected and interesting, not a bug.

---

## Known Problems and Gotchas

### P1: Zero-delay cycles will hang the simulator

If any feedback cycle has total delay = 0, event processing will not terminate. The simulator should detect this during circuit validation (before simulation starts) by checking for cycles where all connection `propagation_delay` values and all node `inertia_delay` values sum to zero.

Mitigation: require `inertia_delay >= 1` on all nodes in feedback paths. Consider making this the default for all nodes.

### P2: Simultaneous events have defined but potentially surprising order

Two events at the same timestamp that affect connected nodes will be processed in insertion order. This can produce transient states that don't reflect physical intuition. In practice this is fine—real circuits can't achieve exactly simultaneous transitions anyway. But test code should not rely on specific intra-timestamp ordering.

### P3: UNRESOLVED in symmetric feedback may never resolve without noise injection

A perfectly symmetric cross-coupled latch will remain `UNRESOLVED` forever without either asymmetric delays or the noise injection mechanism. The noise threshold and injection mechanism need to be tuned to be rare enough to be physically meaningful but reliable enough to not leave simulations stuck.

### P4: Uninitialized components start FLOATING, which may be unexpected

A freshly instantiated register with no reset input will have all flip-flop nodes in FLOATING state. Circuits that assume a known initial state must explicitly drive a reset. Contracts should check for FLOATING where HIGH or LOW is assumed.

### P5: Switch control states are not graduated

The current model treats control as binary: HIGH conducts, LOW does not. Real transistors have a gradual transfer characteristic. This is an acceptable approximation for digital logic but means that a switch with a WEAK HIGH control will not conduct—it will be treated as open. This is intentional and physically conservative.

### P6: CONFLICT propagation is isolated, which may hide bugs

CONFLICT nodes do not propagate to neighbors. This keeps failures local but means a shorted wire might not immediately cause visible downstream effects. Contracts that check for CONFLICT on any node are the right tool for catching this.

---

## Open Questions

1. **PMOS switches:** Start with NMOS-only (simpler) or include PMOS from the start (enables CMOS gates, no pull-ups needed)? NMOS-only is faster to implement; PMOS makes real gate topologies possible without resistors.

2. **Time representation:** Integer ticks (simple, no rounding) or floating-point (more natural for delay values)? Integer ticks are strongly recommended—floating-point comparison of event times is a source of subtle bugs.

3. **Noise injection mechanism:** Should UNRESOLVED nodes automatically receive noise after a threshold, or should noise be explicitly injected by the test bench? Automatic injection is convenient; explicit injection is more controllable.

4. **Contract evaluation granularity:** Are contracts evaluated once at end of simulation, or can they register time-windowed checks ("this invariant must hold from T=100 to T=200")? The latter is more powerful but harder to implement.

5. **Component instantiation vs definition:** Should components be defined once and instantiated many times (like a class), or is each component a unique subgraph? Instantiation enables reuse but requires careful handling of node identity.

6. **ISA definition:** When do we define the CPU's instruction set? This is not a simulator question but it shapes what Level 3 and Level 4 subsystems look like. A minimal ISA (load, store, add, branch) is enough to run small programs.

7. **Cycle detection:** Should the simulator actively detect and warn about zero-delay cycles at circuit build time, or fail at runtime? Build-time detection is friendlier.

8. **Maximum generation rate:** Should the simulator enforce a maximum `generation` increment rate per unit time as a runaway guard? This would catch zero-delay cycles and oscillating circuits before they run forever.

---

## Key Invariants

1. Only nodes hold state—nothing else has memory
2. All influence on nodes is via drive intents
3. Time determines causality—no event may affect the past
4. Contracts do not influence physics—they read traces only
5. Randomness is seeded and controlled—the simulation is reproducible

---

## Summary

> A small deterministic universe where signals argue over time, and logic emerges from their interactions.

The goal is a CPU built from eight primitive types, with every layer fully testable and contractually specified. The interesting moments are when emergence surprises you: a glitch cascade settling into a stable carry, a latch resolving from metastability, a clock domain crossing failing in exactly the predicted way.

Bitta is:
- Small enough to understand completely
- Principled enough to reason about formally
- Complex enough to produce genuine surprises
