# Bitta: Design Document

This document specifies how to implement the concepts from `concept.md`. It covers data structures, algorithms, module responsibilities, and the order in which to build things. The target audience is someone sitting down to write the first line of code.

Language conventions in this document are Python-flavored (dataclasses, type hints, `|` for union types), but the design applies to any typed language.

---

## Modules

```
bitta/
  core/
    signal.py       # Signal enum and DriveIntent
    node.py         # Node, resolution algorithm
    connection.py   # Connection
    switch.py       # Switch
    source.py       # ConstantSource, SignalSource
    event.py        # Event, EventQueue
    circuit.py      # Circuit: the live world state
    simulator.py    # run loop and termination
  trace/
    store.py        # TraceStore, NodeTrace
    query.py        # query helpers (state_at, stable_for, ...)
  contract/
    contract.py     # Contract protocol
    result.py       # ContractResult
  component/
    definition.py   # ComponentDefinition
    builder.py      # CircuitBuilder API
  tests/
    test_node.py
    test_switch.py
    test_gates.py
    test_latch.py
    test_flipflop.py
```

Dependencies run downward only: `trace` depends on `core`, `contract` depends on `trace`, `component` depends on `core` and `contract`. Nothing in `core` knows about contracts.

---

## Core Types

### Signal

```python
class Signal(Enum):
    LOW        = "LOW"
    HIGH       = "HIGH"
    FLOATING   = "FLOATING"
    UNRESOLVED = "UNRESOLVED"
    CONFLICT   = "CONFLICT"
    UNKNOWN    = "UNKNOWN"
```

Only `HIGH` and `LOW` are valid as drive intent values. The rest are resolved states only.

### Strength and DriveIntent

```python
class Strength(Enum):
    STRONG = "STRONG"
    WEAK   = "WEAK"

@dataclass(frozen=True)
class DriveIntent:
    source_id: str        # identifies which primitive is driving
    value:     Signal     # HIGH or LOW only
    strength:  Strength
```

`source_id` is the string ID of the switch, pull-up, VCC, GND, or connection that is producing the drive. It is the key in the node's driver dict—each source can only have one active intent at a time.

---

## Node

```python
@dataclass
class Node:
    id:                          str
    current_state:               Signal = Signal.FLOATING
    candidate_state:             Signal = Signal.FLOATING
    pending_transition_event_id: int | None = None
    drivers:                     dict[str, DriveIntent] = field(default_factory=dict)
    inertia_delay:               int = 1
    generation:                  int = 0
    _switch_listeners:           list[Switch] = field(default_factory=list)
    _outgoing_connections:       list[Connection] = field(default_factory=list)
```

`_switch_listeners` is the set of switches whose control or input is this node. `_outgoing_connections` is the set of connections originating from this node. Both are populated at circuit build time and never change after that.

### Resolution

```python
def resolve(drivers: dict[str, DriveIntent]) -> Signal:
    if not drivers:
        return Signal.FLOATING

    strong = [d for d in drivers.values() if d.strength == Strength.STRONG]
    weak   = [d for d in drivers.values() if d.strength == Strength.WEAK]

    if strong:
        has_high = any(d.value == Signal.HIGH for d in strong)
        has_low  = any(d.value == Signal.LOW  for d in strong)
        if has_high and has_low:
            return Signal.CONFLICT
        return Signal.HIGH if has_high else Signal.LOW

    has_high = any(d.value == Signal.HIGH for d in weak)
    has_low  = any(d.value == Signal.LOW  for d in weak)
    if has_high and has_low:
        return Signal.UNRESOLVED
    return Signal.HIGH if has_high else Signal.LOW
```

### Driver Mutation

All changes to a node's driver set go through these two methods. They immediately re-run resolution and schedule transitions as needed.

```python
def set_driver(self, intent: DriveIntent, now: int, queue: EventQueue) -> None:
    old = self.drivers.get(intent.source_id)
    if old == intent:
        return
    self.drivers[intent.source_id] = intent
    self._recompute(now, queue)

def remove_driver(self, source_id: str, now: int, queue: EventQueue) -> None:
    if source_id not in self.drivers:
        return
    del self.drivers[source_id]
    self._recompute(now, queue)
```

### Recompute and Transition

```python
def _recompute(self, now: int, queue: EventQueue) -> None:
    new_candidate = resolve(self.drivers)
    if new_candidate == self.candidate_state:
        return

    self.candidate_state = new_candidate

    # cancel any pending transition
    if self.pending_transition_event_id is not None:
        queue.cancel(self.pending_transition_event_id)
        self.pending_transition_event_id = None

    if self.candidate_state != self.current_state:
        eid = queue.schedule(now + self.inertia_delay,
                             lambda: self._commit(now + self.inertia_delay, queue))
        self.pending_transition_event_id = eid

def _commit(self, now: int, queue: EventQueue) -> None:
    self.current_state = self.candidate_state
    self.generation += 1
    self.pending_transition_event_id = None
    # notify everything watching this node
    for switch in self._switch_listeners:
        switch.evaluate(now, queue)
    for conn in self._outgoing_connections:
        conn.schedule_propagation(now, queue)
```

The trace system hooks into `_commit` by registering a callback (see Trace section).

---

## Connection

Connections are **unidirectional** and represent a wire with propagation delay. Drive intent flows from source to target only.

```python
@dataclass
class Connection:
    id:                str
    source_node_id:    str
    target_node_id:    str
    propagation_delay: int = 1
```

When the source node commits a state change, it calls `schedule_propagation`. At time + delay, the connection updates the target node's driver:

```python
def schedule_propagation(self, now: int, queue: EventQueue) -> None:
    queue.schedule(now + self.propagation_delay,
                   lambda: self._propagate(now + self.propagation_delay, queue))

def _propagate(self, now: int, queue: EventQueue) -> None:
    source_state = circuit.node(self.source_node_id).current_state
    target = circuit.node(self.target_node_id)

    if source_state in (Signal.HIGH, Signal.LOW):
        target.set_driver(
            DriveIntent(self.id, source_state, Strength.STRONG),
            now, queue
        )
    else:
        target.remove_driver(self.id, now, queue)
```

The strength is always `STRONG`. A resolved HIGH or LOW on a wire is a full-voltage signal regardless of what produced it.

**Bidirectional wires** are two unidirectional connections with matching delay. For most intra-component wiring, share the same `NodeId` instead—zero delay, no connection needed.

---

## Switch

```python
class Polarity(Enum):
    NMOS = "NMOS"   # conducts when control = HIGH
    PMOS = "PMOS"   # conducts when control = LOW

@dataclass
class Switch:
    id:              str
    control_node_id: str
    input_node_id:   str
    output_node_id:  str
    polarity:        Polarity = Polarity.NMOS
```

A switch emits a single `STRONG` drive intent on its output, sourced from `self.id`. When conducting, the value mirrors the input node's current state. When not conducting, the drive is removed.

```python
def evaluate(self, now: int, queue: EventQueue) -> None:
    control_state = circuit.node(self.control_node_id).current_state
    input_state   = circuit.node(self.input_node_id).current_state
    output_node   = circuit.node(self.output_node_id)

    conducting = (
        (self.polarity == Polarity.NMOS and control_state == Signal.HIGH) or
        (self.polarity == Polarity.PMOS and control_state == Signal.LOW)
    )

    if conducting and input_state in (Signal.HIGH, Signal.LOW):
        output_node.set_driver(
            DriveIntent(self.id, input_state, Strength.STRONG),
            now, queue
        )
    else:
        output_node.remove_driver(self.id, now, queue)
```

`evaluate` is called:
- When the control node commits a state change
- When the input node commits a state change

Both `control_node` and `input_node` register the switch in their `_switch_listeners` at build time.

**Undefined control:** any control state other than HIGH or LOW is treated as open (non-conducting). Garbage in, nothing out.

---

## Signal Sources

Signal sources inject the initial drives into the simulation. They are the only things that add drivers to nodes without being triggered by another node.

```python
@dataclass
class ConstantSource:
    id:       str
    node_id:  str
    intent:   DriveIntent

    def initialize(self, now: int, queue: EventQueue) -> None:
        circuit.node(self.node_id).set_driver(self.intent, now, queue)
```

`ConstantSource` is used for VCC, GND, pull-ups, and pull-downs:

```python
def make_vcc(node_id: str) -> ConstantSource:
    return ConstantSource(f"vcc:{node_id}", node_id,
                          DriveIntent(f"vcc:{node_id}", Signal.HIGH, Strength.STRONG))

def make_gnd(node_id: str) -> ConstantSource:
    return ConstantSource(f"gnd:{node_id}", node_id,
                          DriveIntent(f"gnd:{node_id}", Signal.LOW, Strength.STRONG))

def make_pull_up(node_id: str) -> ConstantSource:
    return ConstantSource(f"pu:{node_id}", node_id,
                          DriveIntent(f"pu:{node_id}", Signal.HIGH, Strength.WEAK))

def make_pull_down(node_id: str) -> ConstantSource:
    return ConstantSource(f"pd:{node_id}", node_id,
                          DriveIntent(f"pd:{node_id}", Signal.LOW, Strength.WEAK))
```

For timed signal sequences:

```python
@dataclass
class ScheduledSource:
    id:       str
    node_id:  str
    schedule: list[tuple[int, DriveIntent | None]]  # (time, intent or None=remove)

    def initialize(self, queue: EventQueue) -> None:
        for time, intent in self.schedule:
            if intent is not None:
                queue.schedule(time, lambda t=time, i=intent:
                    circuit.node(self.node_id).set_driver(i, t, queue))
            else:
                queue.schedule(time, lambda t=time:
                    circuit.node(self.node_id).remove_driver(self.id, t, queue))
```

---

## Event Queue

```python
@dataclass(order=True)
class Event:
    time:      int
    sequence:  int                       # insertion order for same-time determinism
    id:        int = field(compare=False)
    cancelled: bool = field(default=False, compare=False)
    action:    Callable[[], None] = field(compare=False)

class EventQueue:
    def __init__(self):
        self._heap:     list[Event] = []
        self._by_id:    dict[int, Event] = {}
        self._seq:      int = 0
        self._next_id:  int = 0

    def schedule(self, time: int, action: Callable[[], None]) -> int:
        eid = self._next_id; self._next_id += 1
        seq = self._seq;     self._seq += 1
        e = Event(time=time, sequence=seq, id=eid, action=action)
        heapq.heappush(self._heap, e)
        self._by_id[eid] = e
        return eid

    def cancel(self, event_id: int) -> None:
        e = self._by_id.get(event_id)
        if e:
            e.cancelled = True

    def pop(self) -> Event | None:
        while self._heap:
            e = heapq.heappop(self._heap)
            if not e.cancelled:
                return e
        return None

    @property
    def empty(self) -> bool:
        return all(e.cancelled for e in self._heap) or len(self._heap) == 0
```

Cancellation is lazy: events are marked cancelled and skipped when popped. This is O(1) cancel and O(log n) push/pop.

---

## Circuit

`Circuit` is the live world state. All other objects hold references into it.

```python
@dataclass
class Circuit:
    nodes:       dict[str, Node]       = field(default_factory=dict)
    switches:    dict[str, Switch]     = field(default_factory=dict)
    connections: dict[str, Connection] = field(default_factory=dict)
    sources:     list[ConstantSource | ScheduledSource] = field(default_factory=list)

    def node(self, node_id: str) -> Node:
        return self.nodes[node_id]

    def add_node(self, node_id: str | None = None, inertia_delay: int = 1) -> str:
        nid = node_id or new_id()
        self.nodes[nid] = Node(id=nid, inertia_delay=inertia_delay)
        return nid

    def add_switch(self, switch_id: str | None = None, *,
                   control: str, input: str, output: str,
                   polarity: Polarity = Polarity.NMOS) -> str:
        sid = switch_id or new_id()
        sw = Switch(sid, control, input, output, polarity)
        self.switches[sid] = sw
        # register listeners
        self.nodes[control]._switch_listeners.append(sw)
        self.nodes[input]._switch_listeners.append(sw)
        return sid

    def add_connection(self, conn_id: str | None = None, *,
                       source: str, target: str,
                       delay: int = 1) -> str:
        cid = conn_id or new_id()
        c = Connection(cid, source, target, delay)
        self.connections[cid] = c
        self.nodes[source]._outgoing_connections.append(c)
        return cid

    def add_vcc(self, node_id: str) -> None:
        self.sources.append(make_vcc(node_id))

    def add_gnd(self, node_id: str) -> None:
        self.sources.append(make_gnd(node_id))

    def add_pull_up(self, node_id: str) -> None:
        self.sources.append(make_pull_up(node_id))

    def add_pull_down(self, node_id: str) -> None:
        self.sources.append(make_pull_down(node_id))
```

---

## Simulator

```python
@dataclass
class SimulationConfig:
    time_limit:      int | None = None
    trace_all_nodes: bool = True

@dataclass
class SimulationResult:
    end_time: int
    traces:   TraceStore
    reason:   str   # "quiescence" | "time_limit" | "contract_violation"

def run(circuit: Circuit, config: SimulationConfig) -> SimulationResult:
    queue = EventQueue()
    traces = TraceStore()
    now = 0

    # wire trace callbacks into all nodes
    if config.trace_all_nodes:
        for node in circuit.nodes.values():
            node._on_commit = lambda n, t: traces.record(n, t)

    # initialize constant sources (t=0)
    for source in circuit.sources:
        source.initialize(0, queue)

    # run
    while True:
        event = queue.pop()
        if event is None:
            return SimulationResult(now, traces, "quiescence")
        if config.time_limit is not None and event.time > config.time_limit:
            return SimulationResult(now, traces, "time_limit")
        now = event.time
        event.action()

    return SimulationResult(now, traces, "quiescence")
```

The `_on_commit` callback on Node is called at the end of `_commit` before notifying listeners. This is the only hook the simulator exposes to the trace layer—physics is otherwise untouched.

---

## Trace

```python
@dataclass
class TraceEntry:
    time:       int
    generation: int
    state:      Signal

@dataclass
class NodeTrace:
    node_id: str
    history: list[TraceEntry] = field(default_factory=list)

    def record(self, time: int, generation: int, state: Signal) -> None:
        self.history.append(TraceEntry(time, generation, state))

class TraceStore:
    def __init__(self):
        self._traces: dict[str, NodeTrace] = {}

    def record(self, node: Node, time: int) -> None:
        if node.id not in self._traces:
            self._traces[node.id] = NodeTrace(node.id)
        self._traces[node.id].record(time, node.generation, node.current_state)

    def trace(self, node_id: str) -> NodeTrace:
        return self._traces.get(node_id, NodeTrace(node_id))
```

### Trace Queries

```python
def state_at(trace: NodeTrace, time: int) -> Signal:
    """Last known state at or before `time`."""
    result = Signal.UNKNOWN
    for entry in trace.history:
        if entry.time <= time:
            result = entry.state
        else:
            break
    return result

def transitions(trace: NodeTrace) -> list[TraceEntry]:
    """All entries where state changed."""
    result = []
    prev = None
    for e in trace.history:
        if e.state != prev:
            result.append(e)
            prev = e.state
    return result

def stable_for(trace: NodeTrace, duration: int, before: int) -> bool:
    """Was the node in the same state for `duration` ticks ending at `before`?"""
    target = state_at(trace, before)
    return state_at(trace, before - duration) == target

def first_time(trace: NodeTrace, state: Signal) -> int | None:
    """First tick the node reached `state`."""
    for e in trace.history:
        if e.state == state:
            return e.time
    return None

def last_rising_edge(trace: NodeTrace, before: int) -> int | None:
    """Last LOW→HIGH transition at or before `before`."""
    result = None
    for e in transitions(trace):
        if e.time > before:
            break
        if e.state == Signal.HIGH:
            result = e.time
    return result
```

---

## Contract

A contract is a plain callable. The MVP contract protocol:

```python
@dataclass
class ContractResult:
    passed:  bool
    message: str = ""

# Protocol / abstract base
class Contract(Protocol):
    name: str
    def check(self, result: SimulationResult) -> ContractResult: ...
```

Example contract for a NOT gate:

```python
@dataclass
class NotGateContract:
    name: str = "NOT gate inverts input"
    input_node:  str
    output_node: str
    settle_time: int = 5  # ticks after input change before checking output

    def check(self, result: SimulationResult) -> ContractResult:
        in_trace  = result.traces.trace(self.input_node)
        out_trace = result.traces.trace(self.output_node)

        for edge in transitions(in_trace):
            expected = Signal.LOW if edge.state == Signal.HIGH else Signal.HIGH
            actual = state_at(out_trace, edge.time + self.settle_time)
            if actual != expected:
                return ContractResult(False,
                    f"at t={edge.time + self.settle_time}: "
                    f"expected {expected}, got {actual}")
        return ContractResult(True)
```

Running contracts:

```python
def check_contracts(contracts: list[Contract],
                    result: SimulationResult) -> list[tuple[Contract, ContractResult]]:
    return [(c, c.check(result)) for c in contracts]
```

Contracts never run during simulation. They receive a completed `SimulationResult` and read traces.

---

## Component System

Components separate definition from instantiation. A **definition** is a factory function. An **instance** records what nodes it owns for diagnostics.

```python
@dataclass
class ComponentInstance:
    name:          str
    terminal_nodes: dict[str, str]   # terminal name → NodeId
    internal_nodes: list[str]        # NodeIds owned by this instance
    sub_instances:  list[ComponentInstance] = field(default_factory=list)
```

A **definition** is a function with the signature:

```python
ComponentBuilder = Callable[[Circuit, dict[str, str]], ComponentInstance]
# receives circuit and a map of terminal_name → pre-allocated NodeId
```

The caller allocates terminal nodes; the definition creates internal nodes and connects everything. This is the cleanest separation: the parent decides where the component plugs in; the component decides its internals.

### Example: NAND Gate

```python
def nand_gate(circuit: Circuit, terminals: dict[str, str]) -> ComponentInstance:
    """
    Terminals: A, B (inputs), Y (output)
    NMOS topology with pull-up on Y.
    """
    mid = circuit.add_node(inertia_delay=1)
    gnd = circuit.add_node(inertia_delay=0)
    circuit.add_gnd(gnd)

    circuit.add_pull_up(terminals["Y"])
    circuit.add_switch(control=terminals["A"], input=mid, output=terminals["Y"])
    circuit.add_switch(control=terminals["B"], input=gnd, output=mid)

    return ComponentInstance(
        name="NAND",
        terminal_nodes=terminals,
        internal_nodes=[mid, gnd]
    )
```

### Example: SR Latch from two NAND gates

```python
def sr_latch(circuit: Circuit, terminals: dict[str, str]) -> ComponentInstance:
    """
    Terminals: S, R (inputs), Q, Q_BAR (outputs)
    """
    q     = terminals["Q"]
    q_bar = terminals["Q_BAR"]
    s     = terminals["S"]
    r     = terminals["R"]

    nand1 = nand_gate(circuit, {"A": s, "B": q_bar, "Y": q})
    nand2 = nand_gate(circuit, {"A": r, "B": q,     "Y": q_bar})

    return ComponentInstance(
        name="SR_LATCH",
        terminal_nodes=terminals,
        internal_nodes=[],
        sub_instances=[nand1, nand2]
    )
```

Note: Q and Q_BAR are both input and output—they are the cross-coupled nodes. The feedback is expressed by passing Q into NAND2 and Q_BAR into NAND1. No special feedback mechanism; the graph just has cycles.

---

## Building a Circuit: End-to-End Example

```python
circuit = Circuit()

# allocate terminal nodes
s     = circuit.add_node()
r     = circuit.add_node()
q     = circuit.add_node()
q_bar = circuit.add_node()

# build SR latch
latch = sr_latch(circuit, {"S": s, "R": r, "Q": q, "Q_BAR": q_bar})

# test bench: drive S=HIGH at t=0, back to LOW at t=20
# drive R=HIGH at t=40, back to LOW at t=60
circuit.sources.append(ScheduledSource(
    id="s_driver", node_id=s,
    schedule=[
        (0,  DriveIntent("s_driver", Signal.HIGH, Strength.STRONG)),
        (20, DriveIntent("s_driver", Signal.LOW,  Strength.STRONG)),
        (40, None),  # release S
    ]
))
circuit.sources.append(ScheduledSource(
    id="r_driver", node_id=r,
    schedule=[
        (0,  DriveIntent("r_driver", Signal.LOW,  Strength.STRONG)),
        (40, DriveIntent("r_driver", Signal.HIGH, Strength.STRONG)),
        (60, DriveIntent("r_driver", Signal.LOW,  Strength.STRONG)),
    ]
))

result = run(circuit, SimulationConfig(time_limit=100))

# check contracts
q_trace     = result.traces.trace(q)
q_bar_trace = result.traces.trace(q_bar)
assert state_at(q_trace, 30)  == Signal.HIGH   # set
assert state_at(q_trace, 70)  == Signal.LOW    # reset
assert state_at(q_bar_trace, 30) == Signal.LOW
```

---

## Simulation Initialization Sequence

Order matters at `t = 0`:

1. All nodes start `FLOATING`, `generation = 0`, no drivers.
2. `ConstantSource.initialize()` calls `node.set_driver(...)` for VCC, GND, pull-ups. This triggers `_recompute`, which schedules transitions at `t = inertia_delay`.
3. `ScheduledSource.initialize()` enqueues future events for timed signals.
4. Simulator pops `t = inertia_delay` events, commits node states, notifies switches and connections.
5. Switches evaluate; if any output node needs a drive update, more events are scheduled.
6. Simulation stabilizes when no more events remain (or time limit).

This means circuits with pull-ups start with all pull-up nodes at `FLOATING` until `t = inertia_delay`, then transition to HIGH. Test code that checks state should check after the circuit has settled, not at `t = 0`.

**Practical convention:** check state at `t >= 3 * inertia_delay` for a fully settled initial state.

---

## Known Implementation Traps

### Trap 1: Lambda capture in event scheduling

In Python, `lambda: self._commit(now, queue)` captures `now` by reference. If `now` changes before the lambda runs, it will use the new value. Use default argument binding: `lambda t=now: self._commit(t, queue)`.

### Trap 2: Modifying drivers during iteration

`set_driver` calls `_recompute`, which may schedule events that call `set_driver` on other nodes. This is safe because it goes through the event queue (deferred). Never call `set_driver` in a loop over `self.drivers`—copy the dict first if needed.

### Trap 3: Switch listener registration order

Both control and input nodes register the switch as a listener. If a switch is added after the circuit has run, the listener won't be registered and the switch will never evaluate. All circuit construction must happen before `run()`.

### Trap 4: Inertia delay = 0 on a cyclic path

If any node in a feedback loop has `inertia_delay = 0` AND its driving connection has `propagation_delay = 0`, `_commit` will call listeners immediately, which may call `set_driver`, which calls `_recompute`, which tries to schedule at `now + 0 = now`... and the loop processes it immediately. This is an infinite recursion, not an infinite loop—it will stack-overflow rather than run forever. Detect this: require `inertia_delay >= 1` on all nodes, enforced at `add_node` time (or at `run()` time via cycle check).

### Trap 5: CONFLICT propagation

A CONFLICT node's state is `CONFLICT`. When connections propagate from this node, they call `set_driver` with `source_state = CONFLICT`. The propagation code must treat `CONFLICT` as "remove drive" (no intent), not as `HIGH` or `LOW`. This is already handled in the `_propagate` method above (`if source_state in (Signal.HIGH, Signal.LOW)`), but double-check this path.

---

## Build Order

Build in this order. Each step has a clear test that proves it works before moving to the next.

```
Step 1: Signal, Strength, DriveIntent
  Test: resolution function with all input combinations

Step 2: Node (without queue)
  Test: set_driver / remove_driver changes drivers dict correctly
        resolve() returns correct state for all cases

Step 3: EventQueue
  Test: schedule, pop in time order
        cancel removes event from processing
        same-time events are deterministically ordered

Step 4: Node with queue (inertia)
  Test: state change is deferred by inertia_delay
        rapid input changes cancel pending transitions
        generation increments on each commit

Step 5: Switch
  Test: NMOS conducts on HIGH control
        PMOS conducts on LOW control
        undefined control → open (no drive on output)
        input FLOATING → no drive on output even when conducting

Step 6: ConstantSource + Circuit + Simulator (minimal run loop)
  Test: VCC drives a node to HIGH after inertia_delay
        GND drives a node to LOW

Step 7: Pull-up + NMOS switch → NOT gate
  Test: input HIGH → output LOW (after settling)
        input LOW → output HIGH

Step 8: Two switches + pull-up → NAND gate (using truth table contract)
  Test: all four input combinations produce correct output

Step 9: Connection
  Test: drive from source appears on target after propagation_delay
        removing source drive removes target drive after delay

Step 10: SR latch
  Test: set latch → Q holds HIGH after S released
        reset latch → Q goes LOW after R released
        invalid state (S=LOW, R=LOW) → both HIGH (NAND behavior)

Step 11: D latch → D flip-flop
  MVP complete.
```

At Step 11, every layer of the stack has been exercised. Traces are readable, contracts check behavior, and emergent memory exists.

---

## What This Does Not Cover (Yet)

- **PMOS switches** — open question; not needed for NMOS-based NAND gates
- **Noise injection** for metastability resolution — relevant once flip-flops are built and symmetry-breaking needs testing
- **Cycle detection at build time** — useful safety check; can be added as a validator that runs before `run()`
- **Generation rate guard** — runaway oscillation detection; add after basic simulation works
- **Multi-seed / Monte Carlo** — deferred until metastability is worth exploring
