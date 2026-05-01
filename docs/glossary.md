# Bitta: Glossary

Quick reference for domain terms used across concept.md and design.md.

---

## Signal States

A `Signal` is the resolved state of a node at a point in time.

| Term | Meaning |
|---|---|
| `LOW` | Logic zero — a stable, driven low voltage |
| `HIGH` | Logic one — a stable, driven high voltage |
| `FLOATING` | No drivers present on the node |
| `UNRESOLVED` | Competing weak drivers with no dominant value |
| `CONFLICT` | Opposing strong drivers (electrical short) |
| `UNKNOWN` | Simulator error sentinel — should never appear in a valid circuit |

`FLOATING` and `UNRESOLVED` are both "no definite value" but arise differently: `FLOATING` means nothing is driving the node; `UNRESOLVED` means multiple things are driving it but they cancel out.

`CONFLICT` is a real circuit condition (a short). `UNKNOWN` is a bug.

---

## Drive Strength

A `DriveIntent` has a `strength` that determines which intents win during resolution.

| Term | Meaning | Examples |
|---|---|---|
| `STRONG` | Active driver — wins over WEAK, conflicts with opposing STRONG | Transistor output, VCC, GND |
| `WEAK` | Passive bias — loses to STRONG, combines with other WEAK | Pull-up resistor, pull-down resistor |

---

## Core Objects

### Node
The fundamental unit of state. Represents a single wire segment (one electrical potential). Holds a set of drive intents from all sources currently driving it, and resolves them to a current state. Does not change state instantly — changes are deferred by `inertia_delay`.

### DriveIntent
An expression of influence on a node: who is driving, to what value, at what strength. A node aggregates all current drive intents and resolves them to a signal state.

### Connection
A unidirectional delay element between two nodes. When the source node's state changes, the target node receives a corresponding STRONG drive intent after `propagation_delay` ticks. Does not generate drive intents itself — it forwards the resolved state of the source.

### Switch
The transistor abstraction. Has three terminals: `control`, `input`, `output`. When conducting, it applies a STRONG drive to `output` matching the state of `input`. Whether it conducts depends on the control node's state and the switch's polarity.

- **NMOS**: conducts when control = HIGH
- **PMOS**: conducts when control = LOW

Undefined control (FLOATING, UNRESOLVED, CONFLICT) → switch is open (conservative).

### Terminal
A named connection point on a component. In implementation, a terminal is just a `NodeId` with a name — the name identifies its role (e.g. `A`, `B`, `Y`, `Q`, `CLK`). The node itself is shared between the component and the parent circuit.

### ConstantSource
A permanent drive intent attached to a node at circuit initialization. Used to implement VCC (`STRONG HIGH`), GND (`STRONG LOW`), pull-up (`WEAK HIGH`), and pull-down (`WEAK LOW`).

### ScheduledSource
A timed sequence of drive intents injected into a node. The test bench: drives signals according to a schedule to stimulate the circuit.

---

## Timing

### Inertia Delay
The minimum number of ticks a node must wait before committing a state change. A node that sees a new candidate state schedules a transition after `inertia_delay`. If the candidate changes again before the delay expires, the pending transition is cancelled and rescheduled.

Effects: glitch filtering, realistic propagation, emergent latch behavior.

### Propagation Delay
The number of ticks a connection takes to deliver a state change from source to target. Distinct from inertia delay — inertia is a property of nodes, propagation is a property of connections.

### Generation
A monotonically increasing integer on each node, incremented every time the node commits a state change. Useful for: detecting runaway oscillation (generation increasing much faster than simulation time) and writing time-independent contracts ("Q was stable for N generations after CLK rose").

### Tick
One unit of simulation time. Time is an integer counter. All delays are in ticks. There is no physical time unit — what matters is the ratio of delays to each other.

---

## Simulation

### Event
A scheduled action: a time (in ticks) and a callable. The simulator processes events in ascending time order. Events at the same time are processed in insertion order (deterministic, not random).

### EventQueue
A priority queue of events. Events can be cancelled by ID (lazy cancellation: marked cancelled, skipped when popped).

### Quiescence
The state where no more events are pending. Simulation terminates when quiescence is reached (or the time limit is hit).

### Circuit
The live world state: all nodes, switches, connections, and sources. Constructed before simulation starts and not modified during simulation.

### SimulationResult
The output of a simulation run: end time, termination reason, and all recorded traces.

---

## Observation

### Trace
The recorded history of a node's state changes: a list of `(time, generation, state)` entries. Collected during simulation without affecting physics.

### TraceStore
Holds all traces for all nodes in a simulation. Contracts and tests read from the TraceStore.

---

## Judgment

### Contract
A function that takes a `SimulationResult` and returns pass/fail. Evaluated after simulation completes — never during. Contracts cannot affect physics.

### ContractResult
A pass/fail result from a contract, with an optional message explaining a failure.

---

## Components

### ComponentDefinition
A factory function that builds a component's internals into a `Circuit` given a set of pre-allocated terminal nodes. The definition is reusable; calling it multiple times creates independent instances.

Signature: `(circuit: Circuit, terminals: dict[str, NodeId]) → ComponentInstance`

### ComponentInstance
A record of one instantiation: the terminal node IDs, the internal node IDs owned by this instance, and any sub-instances. Used for debugging and diagnostics. The simulator does not use it — it only cares about nodes and connections.

---

## Circuit Patterns

### Fan-out
One output node driving multiple input nodes. Implemented by connecting the same source node to multiple switch controls or connection targets. No special mechanism required.

### Cross-coupling
Two nodes where each feeds into a gate that drives the other. The basis of SR latches and flip-flops. Implemented as a cyclic graph — the simulator handles cycles naturally through propagation delay and inertia.

### Pull-up / Pull-down Network
A `WEAK` drive intent on a node that establishes a default state when no `STRONG` driver is active. A pull-up provides `WEAK HIGH`; a pull-down provides `WEAK LOW`. Used in NMOS logic to bias outputs HIGH when no switch is conducting.
