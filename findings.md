# Findings

- `obs-zoom-to-mouse-cn.lua` at `HEAD` is the crop-based enhanced version.
- User wants transform-based zoom rebuilt from current codebase, not another rollback to the crop approach.
- Need to preserve Chinese UI and later-added features after transform core is stable.
- Both `obs-zoom-to-mouse.lua` and `obs-zoom-to-mouse-cn.lua` in git history are crop-filter implementations.
- The enhanced Chinese script adds auto-start, dynamic aspect ratio, auto zoom-out, typing detection, socket support, and extra hotkeys on top of the crop baseline.
- There is no transform-based version in git history to restore from; transform mode must be redesigned from the current source.
- The old script had a restore bug in `release_sceneitem()`: it called `obs_sceneitem_get_info2` instead of `obs_sceneitem_set_info2`, so original transform state was never restored.
- The new transform model uses one consistent coordinate pipeline: desktop mouse -> monitor offset -> crop offset -> source-local visible area -> canonical top-left sceneitem transform.
- To avoid preview drift, zoom now clamps a source-local visible window and derives sceneitem `pos/scale` from that window, instead of mixing crop space and canvas space.
- To avoid recursive `item_transform` churn, script-driven transform writes are guarded by `suppress_transform_update`.
