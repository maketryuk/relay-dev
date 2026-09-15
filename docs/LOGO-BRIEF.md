# Relay — logo brief

## What the product is

Relay is a native macOS workspace manager for developers. It puts projects,
terminal sessions, AI coding agents (Claude Code, Codex), dev servers, Docker
containers and SSH hosts behind one dark, keyboard-driven window.

Its defining technical idea: the processes do not belong to the window. A
background daemon owns every terminal, so closing the app never kills a running
agent. The app is the surface you look through, not the thing doing the work.

Its defining product promise: with several projects open you can tell at a
glance where something is running, where an agent is waiting for your answer,
and where work has finished — without switching to any of them.

## What the mark should say

One of these ideas, not all of them:

- **Relaying** — a signal handed from one runner to the next; continuity across
  a handoff. The name is literal: the app relays between you and your tools.
- **Persistence** — something that keeps running while you are not watching.
- **A single pane over many streams** — parallel lines of work, one place to
  see them.

Avoid: a literal terminal window with a `>_` prompt, a chat bubble, a robot, a
brain, a rocket. Every developer tool has those, and none of them is what Relay
does.

## Visual constraints

- Works as a macOS app icon: legible at 16×16, still interesting at 1024×1024.
  If it stops reading at 16 px, it is wrong.
- Reads on near-black (`#08090A`) — the app is very dark — and must also survive
  on white.
- Geometric and precise rather than hand-drawn or illustrative. Thick enough
  strokes to survive downscaling.
- Flat or a single subtle gradient. No bevels, no glows, no drop shadows.
- Monochrome version must work: the shape has to carry the idea on its own.

## Palette

The app reserves colour almost entirely for runtime status, and the icon may
borrow from that vocabulary:

- blue `#58A6FF` — working
- amber `#E3B341` — waiting for you
- green `#3FB950` — finished
- red `#F85149` — error
- accent blue `#4C8DFF`, near-black `#08090A`, off-white `#E8ECEE`

Two colours maximum, plus the background. A three-colour version is acceptable
only if the colours are doing the "status" idea deliberately.

## Format

Square macOS app icon, rounded-square (squircle) silhouette in the Apple style,
with the mark inset — Apple's grid leaves roughly 10% padding on each side.
Deliver as SVG plus a 1024×1024 PNG.

## One-paragraph prompt for a generator

> A minimal, geometric app icon for "Relay", a native macOS developer tool that
> keeps terminal sessions and AI coding agents running in the background. Flat
> vector, squircle tile in near-black `#08090A`, with a precise abstract mark in
> `#4C8DFF` suggesting a signal being handed forward — a baton pass, offset
> parallel strokes, or a continuous line stepping between two anchor points.
> Two colours maximum. No text, no terminal prompt, no robot, no gradients
> beyond a single subtle one. Thick, confident strokes that stay legible at
> 16×16. Centred, generous padding, symmetrical composition.

## Three directions worth trying

1. **The baton.** Two offset strokes with a small gap where one hands off to the
   other. The gap is the idea: the work continues across it.
2. **The stepped line.** A single line that steps up through two or three
   levels, each step a different status colour. Reads as progress across
   parallel tracks.
3. **The persistent dot.** A ring, broken at the top, with a filled dot resting
   in the break — the app is the ring you can open and close, the dot is the
   process that stays. This one also scales down best.
