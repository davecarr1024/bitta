# Bitta: Concept Design Document

## Overview

**Bitta** is an event-driven digital circuit simulator built from minimal primitives that approximate real electrical behavior without modeling full analog physics.

The core idea:

> **Digital logic is not assumed—it emerges from interactions between simple components over time.**

Bitta separates:
- **Physics** (simulation of nodes, connections, and signals)
- **Observation** (trace and state history)
- **Judgment** (contracts, lemmas, and correctness)

---

## Design Principles

### 1. Physics is Dumb and Honest
Simulation does not enforce correctness. It only answers:

> *What happened?*

### 2. Contracts are External
Correctness is evaluated separately:

> *Was that acceptable?*

### 3. Composition First
All behavior emerges from composing small primitives:
- Nodes
- Connections
- Terminals
- Switches
- Weak/strong drivers

### 4. Time is Continuous (Event-Based)
- No global tick
- Events occur at discrete timestamps
- Signals propagate with delay

### 5. Deterministic Chaos
- Simulation is deterministic given a seed
- Controlled randomness enables exploration (Monte Carlo)

---

## Core Concepts

### Nodes

A **node** is the fundamental unit of truth.

```
Node:
  id
  current_state
  candidate_state
  drivers
  inertia_delay
  generation
```

Nodes:
- Aggregate drive intents
- Resolve to a state
- Change over time via events

#### Node States

| State | Meaning |
|---|---|
| `LOW` | Logic zero |
| `HIGH` | Logic one |
| `FLOATING` | No drivers |
| `UNRESOLVED` | Competing or insufficient dominance |
| `CONFLICT` | Strong opposing drives |
| `UNKNOWN` | Invalid abstraction or corruption |

- `FLOATING`: no drivers
- `UNRESOLVED`: competing or insufficient dominance
- `CONFLICT`: strong opposing drives
- `UNKNOWN`: invalid abstraction or corruption

---

### Drive Intents

All influence on nodes is expressed as drive intents:

```
DriveIntent:
  value: HIGH | LOW
  strength: STRONG | WEAK
```

| Strength | Meaning |
|---|---|
| `STRONG` | Active driver (transistor-like) |
| `WEAK` | Passive bias (pull-up / pull-down) |

Examples:
- VCC → `STRONG HIGH`
- GND → `STRONG LOW`
- Pull-up → `WEAK HIGH`
- Pull-down → `WEAK LOW`

---

### Node Resolution

Node state is derived from all active drive intents.

#### Resolution Rules

```
if no drivers:
  → FLOATING

if STRONG HIGH + STRONG LOW:
  → CONFLICT

if STRONG present:
  STRONG dominates WEAK

if only WEAK:
  all same → HIGH or LOW
  mixed    → UNRESOLVED
```

This produces a candidate state.

---

### Node Inertia (Critical Behavior)

Nodes do not change instantly.

```
if candidate != current:
  schedule transition after inertia_delay
```

If inputs change before the delay expires:
- cancel pending transition
- recompute

#### Effects
- Glitch filtering
- Temporal competition
- Emergent metastability
- Realistic propagation

---

### Connections (Wires)

A connection links nodes with delay.

```
Connection:
  node_a
  node_b
  propagation_delay
```

Behavior:
```
on node change:
  schedule propagation to connected nodes
```

Connections:
- Carry drive intent
- Introduce delay
- Do not enforce correctness

---

### Terminals

A terminal connects a component to a node.

```
Terminal:
  internal_node
  external_node
```

Behavior:
- Propagates signals across component boundary
- Does not enforce rules
- Acts as a special connection

#### Key Property

> A terminal is a connection with identity and context.

---

### Components

A component is a subgraph:

```
Component:
  internal nodes
  internal connections
  terminals
```

Components:
- Encapsulate topology
- Define reusable behavior
- Expose terminals for composition

---

### Weak vs Strong Drives

This is a core abstraction:

| Type | Meaning |
|---|---|
| `STRONG` | Actively drives |
| `WEAK` | Default preference |

**Analogy:**
- `STRONG` = grabbing the steering wheel
- `WEAK` = suggesting a direction

---

### UNRESOLVED (Key Insight)

`UNRESOLVED` is not an error—it is a state of competition.

It arises from:
- Balanced weak drives
- Close timing races
- Feedback loops

#### Behavior
- Propagates through system
- May persist
- May resolve via timing or noise

---

### Metastability (Emergent)

Metastability is not special-cased.

It is:
- `UNRESOLVED` + feedback + time

Resolution occurs via:
- Small timing differences
- Seeded randomness
- Amplification in feedback loops

---

### Time Model

Simulation is event-driven:

```
Event:
  time
  action
```

Rules:
- Events at same time are simultaneous
- No ordering bias within a timestamp
- New events scheduled in future only

---

### Clock Model

Clocks are not special.

They are signal sources that emit events.

Examples:
- `ManualStepSource`
- `PulseSource`
- `SquareWaveSource`

**Important distinction:** simulation time ≠ circuit clock

---

### Feedback and Latches

Feedback loops are allowed.

Example:
- Cross-coupled NAND gates → SR latch

Behavior emerges from:
- Propagation delay
- Inertia
- Feedback reinforcement

---

### Contracts and Lemmas

Contracts describe expected behavior. They are evaluated after or during simulation.

```
Contract:
  assumptions
  guarantees
  permitted failures
```

Example:
```
D latch:
  assume setup/hold satisfied
  guarantee Q follows D
```

Contracts do not affect physics.

---

### Simulation vs Validation

| Layer | Responsibility |
|---|---|
| Simulation | What happened |
| Contracts | Was it valid |

---

## Minimal Primitive Set

- Node
- Connection
- Terminal
- Switch
- VCC
- GND
- Pull-up (weak)
- Pull-down (weak)

From these, all logic emerges.

---

## Key Invariants

1. Only nodes hold truth
2. All influence is via drive intents
3. Time determines causality
4. Contracts do not influence physics

---

## Summary

> A small deterministic universe where signals argue over time, and logic emerges from their interactions.

Bitta is:
- Simple at the core
- Expressive through composition
- Rich in behavior through timing and competition
