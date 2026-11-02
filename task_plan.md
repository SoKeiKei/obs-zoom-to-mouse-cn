# Task Plan

## Goal
- Rebuild `obs-zoom-to-mouse-cn.lua` from the current crop-based baseline into a transform-based zoom implementation.
- Keep zoom/follow smooth, prevent preview drift/misalignment, and restore enhanced features after the transform core is stable.

## Phases
- [completed] Audit current Chinese and English scripts plus git history
- [completed] Define transform-space coordinate model and invariants
- [completed] Implement minimal transform zoom and smooth follow
- [in_progress] Reintroduce enhanced features on top of stable transform core
- [pending] Validate syntax and runtime assumptions

## Constraints
- Preserve Chinese UI strings where possible
- Avoid broad rewrites until transform core is proven
- Record discoveries and failed approaches before changing direction

## Errors Encountered
- Previous attempt corrupted UTF-8 text and script structure; reverted to git baseline before proceeding
