# Poly-Vis — Architecture Reference

Godot 4.6 (Forward Plus) runtime visualization tool for low-poly meshes,
GPU particle flow fields, and interactive influence fields.

---

## Directory layout

```
scripts/          GDScript source — one class per file, named to match the class
shaders/          GLSL shaders — one per visual system
scenes/           Main.tscn (editor), ParticleDemo.tscn (standalone demo)
resources/        logos/ holds the bundled HUD logo PNGs; other assets go here
addons/           Third-party plugins (optitrack_plugin — see OptiTrack section)
CLAUDE.md         This file
```

---

## Scene hierarchy (Main.tscn)

```
Main [Node3D]                  Main.gd — root coordinator
├── WorldEnvironment           White background + SSAO, Filmic tonemap
├── KeyLight / FillLight       Two DirectionalLight3D nodes
├── Camera3D                   OrbitCamera.gd — mouse orbit/pan/zoom
│
├── VisualizationManager       VisualizationManager.gd — object registry
│   ├── PolyMesh               Default mesh (built into scene)
│   ├── Influence              Default influence (built into scene)
│   └── SelectionGizmo         Added at runtime by Main._ready()
│
├── InfluenceController        Pushes influence uniforms each frame
├── CaptureManager             Added at runtime — screenshot + recording
├── InputManager               Added at runtime — keyboard shortcuts
├── PostFX [CanvasLayer]       Added at runtime — full-screen post pass (layer 0, in captures)
├── HudLogo [CanvasLayer]      Added at runtime — logo overlay (layer 0, in captures)
│
└── UI [CanvasLayer]           layer 1 — hidden during capture
    ├── ParameterPanel         Right-docked control panel (384 px)
    └── FPS label              Top-left corner, added at runtime
```

---

## Core classes

### VisualizationManager
Central object registry. All managed objects (`PolyMesh`, `PolyParticles`,
`InfluenceObject`) are direct children. Emits `objects_changed` and
`selection_changed(obj)`.

Adds come in two flavors. The **undo-free primitives** `spawn_mesh()`,
`spawn_particles()`, `spawn_cloth()`, `spawn_trails()`, `spawn_metaballs()`,
`spawn_strands()`, `spawn_boids()`, `spawn_voronoi()`, `spawn_lightfield()`,
`spawn_influence(select_after=true)` register
an object without
touching undo history — used by CompositionIO (load / preset / duplicate) and
InfluenceController's auto-bind, where a batch appears without meaning a user
"add". The **user-facing** `add_mesh()` / `add_particles()` / `add_cloth()` /
`add_trails()` / `add_metaballs()` / `add_strands()` / `add_boids()` /
`add_voronoi()` / `add_lightfield()` / `add_influence(select_after=true)` wrap the
matching primitive and, when `undo` is set, record a single undo step via
`_record_add()` (see UndoHistory). `spawn_influence(false)` /
`add_influence(false)` skip the normal select-on-add so a silent auto-spawn
doesn't steal panel focus.

Removal: `remove(obj)` is the undo-free primitive — it frees a specific managed
object without disturbing the current selection unless `obj` was it (reselecting
a neighbor), used by auto-bind to despawn a stale influence in the background and
by the undo action itself. `remove_selected()` is the user-facing delete: with an
`undo` present it routes the removal *through* a recorded action (so it's
undoable); without one it falls back to a plain `remove(selected)`. Other key
methods: `clear_all()`, `select(obj)`.

`undo` (a `UndoHistory`, set by Main) is what gates all of the above — the
undo-free `spawn_*`/`remove()` never reference it, so composition loads, preset
applies, duplication, and auto-bind stay out of the history entirely.

### PolyMesh
Procedural icosphere. Build pipeline:
1. `_generate_icosphere()` — subdivides 12-vertex base; uses `_effective_subdivisions`
   (may be lower than `subdivisions` when LOD is active).
2. `_displace_vertices()` — static Simplex noise via FastNoiseLite.
3. `_build_solid_surface()` — unique vertex per face → flat normals.
4. `_build_lattice()` — MultiMesh of cylinder edges + sphere vertex nodes.
5. `_apply_render_mode()` — SOLID / WIREFRAME / SOLID_WIREFRAME toggle.

Setters call `rebuild()` for geometry changes, `_apply_color_and_polish()` for
shader-only changes, or `_update_anim_uniforms()` for animation params.

The solid surface animates on the GPU (shader vertex stage). `animate_lattice`
also animates the wireframe/lattice: `_update_lattice_anim()` recomputes the
MultiMesh transforms each frame from `_anim_offset()`, which mirrors the shader's
displacement using `AshimaNoise.snoise3` (the CPU port of the shader's `snoise`)
so the lattice tracks the surface — important in SOLID_WIREFRAME. Only runs when
the lattice is visible; restores the static lattice once when toggled off. The
surface shader is `cull_disabled` (double-sided) so heavily-displaced meshes that
fold over themselves don't show the background through the folds.

LOD system (`lod_enabled`, `lod_dist1`, `lod_dist2`): `_update_lod()` runs
each frame when enabled, reduces subdivision level by 1 or 2 beyond the
configured distances, rebuilds only when the level changes.

### PolyParticles
`GPUParticles3D` with a custom `shader_type particles` process material
(`particle_flow.gdshader`). Emitter shapes: Point, Sphere, Box, Mesh Surface.
Mesh-surface emission bakes target vertices into a `FORMAT_RGBF` `ImageTexture`.
`emitter_size` scales the spawn volume uniformly (raise it to lower density
without changing count — pushed as `u_emitter_extents * emitter_size`).

Particle draw shapes (`particle_shape`): Sphere, Tetra, Shard, Disc, Spark,
Streak. Streak is a thin tall box that stays upright (rotation 0) for falling-rain
looks. All built at unit scale; `particle_size` sets world size in the shader.

Color: colormap OR `color_a`/`color_b` lerp OR a **palette** of up to 6 toggleable
colors (`palette_enable_1..6` + `palette_color_1..6`). `_apply_palette()` packs the
enabled slots into `u_palette[6]` + `u_palette_count`; when count > 0 each particle
takes a flat random palette color (overrides colormap/lerp), else the old paths.

`follow_influence`: when true the InfluenceController moves the whole system to the
active influence's position each frame (emitter rides along) and applies no force.

Auto-budget (`auto_budget`, `budget_target_fps`): `_process` samples FPS once
per second and scales `amount` proportionally to keep near the target FPS.

### PolyCloth
`MeshInstance3D` rendering a sprawling crumpled-cloth surface — a heavily
domain-warped subdivided plane (vs PolyMesh's centered icosphere). `_build_surface()`
bakes a `(resolution+1)²` grid: domain-warped FBM height along Y (`amplitude`,
`frequency`, `warp`) plus lateral XZ `fold` offsets. `amplitude_variance` (+
`_scale`) modulates the per-vertex `local_amp` by a separate low-frequency noise
field so the sheet has tall dramatic zones and flatter calm zones instead of a
uniform height (0 = uniform). Emits unique verts per
triangle for flat normals. Per-vertex height-noise + fold magnitude are packed
into UV2 for the shader's FOLD/NOISE color sources. Uses `polycloth.gdshader`;
no wireframe/lattice. Setters mirror PolyMesh (`rebuild` for geometry,
`_apply_color_and_polish` / `_update_anim_uniforms` otherwise). Implements
`set_influences()` — folds dent under influence spheres like the mesh.

Curvature warp (`curvature_amount`, `curvature_complexity`, `shape_seed`): a
large-scale 3D bend layered on top of the crumple, folding the sheet into bowls
/ saddles / scrolls. `_build_curvature_lobes()` derives `curvature_complexity`
smooth low-freq bend lobes deterministically from `shape_seed` (RNG); each
vertex sums them via `_curvature_offset(u, v)`. Same seed → same shape, so the
whole form serializes as one int. `randomize_shape()` (exposed as an `action`
button) re-seeds `noise_seed` + `shape_seed` for a fresh unique shape and forces
`curvature_amount` on if it was zero.

Curl (`curl_amount`, `curl_axis`): a deterministic roll (vs the random curvature
lobes) that wraps the whole sheet around one planar axis into an open C / scroll.
`_curl_offset()` treats the chosen axis as arc length around a cylinder of radius
`2*extent / total` where `total = curl_amount * TAU * 0.92` (≤ ~331°, so the sweep
stays under a full turn and leaves the C's mouth): following the axis the surface
rises, curls over the top, and circles back. The arc is centered on the circle's
center (origin), so raising `curl_amount` tightens the C in place rather than
launching the sheet upward (stable camera framing). It's an additive offset, so the
crumple/fold rides along on top. `curl_axis` picks Z (front-back) or X
(left-right). All four cloth presets use it for a significant curve.

Holes (`hole_amount`, `hole_scale`): punches actual gaps through the sheet. During
the triangle pass `_build_surface()` samples a per-quad hole noise field at each
quad center and drops the quad (skips both its triangles) when the sample exceeds
`hole_threshold = 1.0 - hole_amount * 1.7` — so higher `hole_amount` removes more
(0 = solid), and `hole_scale` (the field frequency) sets hole size/count. Holes
follow quad edges (low-poly torn-fabric rims); the `cull_disabled` shader shows the
cloth underside through them. Geometry-level, so `set_hole_*` call `rebuild()`.

### PolyTrails
`MeshInstance3D` that leaves flowing, fading ribbons chasing moving anchors —
the counterpart to the static surfaces. Maintains `strand_count` strands, each a
short world-space history of anchor samples; `_process` glues every strand's
head to its live anchor each frame and commits a new trailing point at
`sample_hz` (so ribbon length is framerate-stable, not tied to render rate),
capping history at `segments`. `_rebuild_mesh()` rebuilds a single shared
`ImmediateMesh` each frame — one camera-facing, width-tapered triangle strip per
strand, with the length param `t` (0 fading tail → 1 head) baked into `UV.x`. The
"side" offset is `cross(segment_dir, to_camera)` so the flat ribbon always faces
the `get_viewport().get_camera_3d()` (falls back to a world-up perpendicular).
Verts are built in local space via `to_local()`, so the node transform still
applies. Anchor per strand `i`: the `attach_to` node if set & valid, else
`influence[i % active_count]` (positions cached from `set_influences()`), else
the node's own position (so with nothing to follow the ribbons harmlessly
collapse to a point — never errors). `spread` + `seed` fan strands out around a
shared anchor via deterministic per-strand offsets (`_rebuild_offsets`). Color
runs along the length through a shared `GradientColormap`; `poly_trails.gdshader`
adds the influence tint using the same `u_influence_*` convention as the
mesh/cloth shaders and fades alpha along `t` (`fade` exponent, `opacity`,
`brightness`). Serialized like the others (schema-driven); the **Ribbon Chase**
preset pairs it with a hidden follow-mouse influence.

### PolyMetaballs
`MeshInstance3D` (a proxy `BoxMesh`) carrying a raymarched SDF shader
(`poly_metaballs.gdshader`) — no CPU mesh rebuild, chosen for LED-wall
performance. Each active influence seeds one sphere in a smooth-minimum (`smin`)
union, so as two influences move together their blobs bulge and merge into one
surface. The shader renders back faces only (`cull_front`) so the volume is
covered whether the camera is inside or outside the box, then **sphere-traces
the SDF from the camera in world space** (empty space is leapt across, so the
`quality` step cap is a ceiling, not a fixed cost), writes true scene `DEPTH` at
the hit, and derives the normal from the SDF gradient. Blob radius per influence
is `blob_radius * (u_influence_radius[i] / 2)` (a default radius-2 influence →
a blob of exactly `blob_radius`); `smoothness` is the `smin` blend width.
Because marching is world-space and influences arrive world-space via
`set_influences()` (the shared fixed-size arrays, MAX_INFLUENCES = 8), the blobs
track influence motion regardless of this node's transform — `bounds` (the box
size) only has to stay big enough to contain them, else blobs clip at the faces.
`motion_stretch` (0 = off) elongates each blob backward along its influence's
recent path into a comet/smear tail: InfluenceController pushes the per-influence
"smear" vectors from its shared trajectory buffer via `set_influence_motion()`
(stored in `u_influence_motion[8]`), and `map()` sweeps each sphere's centre from
the current position toward the trailing samples — a one-sided capsule (clamping the
projection to `[0, len]` so only the tail elongates, not a symmetric capsule). A
still influence has zero motion, so it's a no-op.
Color reuses `GradientColormap` (`color_source`: World Height / Distance /
Normal) plus the posterize / contrast / rim / influence-tint conventions from
`polymesh_deform.gdshader`. `quality` (max steps) and `surface_eps` are the
GPU-cost knobs, flagged in the schema hints. Schema-driven serialization; the
**Merging Blobs** preset seeds it with two hidden influences (one follow-mouse)
so dragging one into the other demonstrates the merge.

### PolyStrands
`MeshInstance3D` rendering a dense field of blades/strands over the y=0 ground
plane — a combable meadow, the strand counterpart to PolyCloth's single sheet.
The static field is baked once on the CPU by `_build_field()`: a flat ground quad
plus `density` tapered blades scattered across `[-extent, extent]²` (deterministic
from `seed`), each a `SEGMENTS`-segment vertical strip that tapers from
`blade_width` at the base to a point at the tip, with a per-blade random yaw +
height variation. Every vertex bakes its normalized height into `UV.y` (0 base →
1 tip) and its blade-root XZ into `UV2`, with a flat baked normal; the ground quad
uses `UV.y = 0` so it stays in the base color and, because all motion scales with
height, perfectly still. `poly_strands.gdshader` does the per-frame motion: an idle
wind `sway` (curl-free position noise, `sway_amount` / `sway_speed`) plus influence
**combing** — for each influence it bends the blade's upper length toward it
(attract, +strength) or away (repel, −strength), by a smoothstep falloff over
`u_influence_radius`, concentrated toward the tip (`t²`) and resisted by
`stiffness`. Implements `set_influences()` with the shared fixed-size (8)
`u_influence_*` convention. Color follows the codebase's colormap-OR-endpoints
idiom: with a `colormap` assigned it tints each blade by a low-frequency meadow
field (shaded base→tip), else the `base_color`→`tip_color` gradient is the
fallback; plus the standard posterize / contrast / rim conventions. Setters mirror
PolyCloth — geometry params (`density`, `extent`, `blade_length`, `blade_width`,
`seed`) call `rebuild()`, motion/color params are cheap uniform pushes
(`_push_motion` / `_apply_color_and_polish`). Schema-driven serialization.

### PolyBoids
`GPUParticles3D` with a custom `shader_type particles` process material
(`poly_boids.gdshader`) — the same engine substrate as PolyParticles, but the
motion is **boid flocking** instead of a curl-noise flow. A particle shader can't
read other particles' state, so the three Reynolds rules are approximated from
shared noise fields keyed off `neighbor_radius` (the flock's characteristic
length): **alignment** follows the local `curl_noise` heading (neighbours sample a
near-identical field, so they travel together), **cohesion** ascends a
low-frequency scalar `grad_noise` field toward the local flock centre, and
**separation** descends a high-frequency one so crowded boids spread apart. The
three weighted rules steer VELOCITY, which is then capped at `max_speed`; `drag`
damps it and `wander_speed` scrolls the fields so flocks drift. Influences act as
**attractors** (+strength, gather) or **predators** (−strength, flee) through the
shared fixed-size (8) `u_influence_*` arrays and `set_influences()`. The shader
orients each particle's mesh so its long +Y axis points along the boid's heading
(so Shard/Streak read as arrows). Reuses PolyParticles' emitter shapes,
`particle_shape` draw meshes, colormap / `color_a`-`color_b` / palette / brightness
(+ `brightness_audio_band`) color paths, and the `auto_budget` FPS-scaling
(`_budget_tick`). It is **not** a PolyParticles subclass (both extend
GPUParticles3D independently), so `VisualizationManager._register` wires the
`audio_reactor` onto `PolyParticles or PolyBoids`, and `_type_label` matches it
separately. Schema-driven serialization.

### PolyVoronoi
`MeshInstance3D` rendering a **fractured** icosphere — PolyMesh's base form split
into Voronoi shards that crack open under the influence field. The build reuses
PolyMesh's `_generate_icosphere` + simplex `_displace_vertices` math verbatim, then
`_assign_cells()` scatters `num_cells` random seed directions on the sphere
(deterministic from `noise_seed`; count derived from `cell_size` and capped to
`tri_count/2` so shards keep ~2 faces), assigns each triangle to its nearest seed
by centroid direction, and computes a per-cell centroid. `_build_fractured_surface()`
emits unique verts per triangle (flat normals) and bakes the cell's object-space
centroid into `CUSTOM0.xyz` + a scattered per-cell id into `CUSTOM0.w` via
`SurfaceTool.set_custom` (`CUSTOM_RGBA_FLOAT`). `poly_voronoi.gdshader` then
translates each cell **as a rigid chunk** outward along its centroid direction, by
the influence proximity evaluated once at the cell centre (same centre + push for
every vertex of the cell, so the shard stays intact and only the seams between
cells open) — the `cull_disabled` backfaces show through the cracks. `shatter_amount`
scales the push, `gap_falloff` sharpens the crack edge; signed influence strength
opens (+) or implodes (−). Reuses the shared colormap / posterize / contrast / rim /
influence-tint uniforms; adds a **Cell** color source (flat per-cell → mosaic,
the default) and a **Shatter** source (lights cells by how far they've opened).
Geometry/cell params `rebuild()`; fracture/color params are cheap uniform pushes
(`_push_fracture` / `_apply_color_and_polish`). Schema-driven serialization.

### PolyLightField
`MultiMeshInstance3D` rendering a flat grid of emissive quads — the on-screen
analogue of the physical LED wall, a reactive pixel field. `rebuild()` bakes a
single MultiMesh: `grid_width × grid_height` unit `QuadMesh` cells laid out centred
in the XY plane, `cell_size` apart, each quad covering `cell_fill` of its cell (so
gaps read as distinct pixels), with `use_custom_data = true` and a per-cell random
shimmer phase written into custom-data.x (+ normalized grid coords in y/z).
`poly_lightfield.gdshader` (`unshaded`) does all the response **per cell in the
vertex stage**: it reads the cell's world position from the MultiMesh instance
origin (`MODEL_MATRIX` translation) and the shared `u_influence_*` arrays,
accumulates a `pow(1-smoothstep, falloff)` distance response weighted by influence
strength, and drives the cell's intensity + colormap hue (dark→cool, bright→hot)
from it, tinting lit cells toward the influence color. An idle shimmer keyed off
the per-cell phase keeps the uninfluenced wall breathing; `idle_brightness` sets
its floor and `cell_gain` pushes lit cells past the glow HDR threshold for bloom.
Deliberately cheap for the LED wall — one MultiMesh, one draw, **no per-frame CPU
work**: `set_influences()` only pushes uniforms and the GPU recomputes every cell.
Grid params `rebuild()`; response/color params are uniform pushes (`_apply_response`
/ `_apply_color`); `_process` pushes `u_time` for the shimmer. Schema-driven
serialization.

### OrbitCamera
Middle-drag orbits (yaw/pitch), Shift+middle-drag pans the target point,
scroll wheel zooms. Exposes `get_param_schema()` so the panel shows camera
controls alongside object controls.

### InfluenceObject
Movable sphere with translucent shell + solid core. Two modes: ATTRACT
(positive signed_strength) or REPEL (negative). When `follow_mouse = true`
the InfluenceController projects the mouse onto a plane through the influence's
world position. `show_visual = false` hides the shell/core meshes (via per-mesh
visibility, not node visibility) while the influence keeps acting — feel the
effect without seeing the source. Meshes show only when `enabled and show_visual`.
`track_rigid_body = true` drives its position from an OptiTrack rigid body
(`rigid_body_asset_id` + `track_position_offset`, optionally `project_to_view`)
instead of the mouse, with the NatNet connection settings + a Connect/Reconnect
action exposed in its panel section — see "OptiTrack motion capture" below.
`track_skeleton_bone = true` instead drives it from one named bone of a
streamed OptiTrack skeleton (`skeleton_asset_id` + `skeleton_bone_name`,
resolved via `OptiTrackSkeletonUtil` — see below) and takes priority over both
`track_rigid_body` and `follow_mouse`; it shares the same
`track_position_offset` / `invert_x` / `invert_z` / `project_to_view` /
`map_to_wall` handling as the rigid-body path.

`velocity_strength_amount` makes a tracked influence react to its own motion
speed: InfluenceController computes world-units/sec each frame from the change
in streamed position (`_update_velocity`) and `effective_signed_strength(speed)`
scales `signed_strength()` by `(1 + speed * velocity_strength_amount)` — the
stored `strength` itself is never mutated, so it's purely a per-frame push-force
multiplier that returns to baseline the instant the rigid body stops (speed → 0).
0 (default) disables it; it's a no-op on untracked influences since their speed
is always 0. `velocity_burst` (off by default) additionally restarts every
PolyParticles within `radius` on a rising-edge crossing of
`velocity_burst_threshold` (world units/sec) — once per crossing, not every
frame the motion stays fast, mirroring `InfluenceController.burst_on_enter`'s
proximity-triggered restart but keyed on speed instead. A live "Speed" status
row (`tracked_speed_status()`, backed by `_tracked_speed` — written each frame
by the controller, not exported/serialized) helps tune the amount/threshold
without eyeballing the 3D view.

### InfluenceController
Runs each frame: gathers enabled influences → packs into fixed-size arrays
(max 8) → calls `set_influences()` on every managed object. Per influence,
`_update_follow()` positions it from a skeleton bone (`track_skeleton_bone`, via
`_skeleton_pos()`), else an OptiTrack rigid body (`track_rigid_body`, via
`_optitrack_pos()`), else from the mouse (`follow_mouse`). Both OptiTrack paths
funnel their raw streamed position through the shared `_apply_tracking_transform()`
(invert_x/z, then map_to_wall / offset+project_to_view) so the mapping options
behave identically regardless of source. A PolyParticles with
`follow_influence` is instead moved to the active influence's position and gets a
0-count (no force). Also handles left-mouse drag on the selected influence and
fires `proximity_entered` / `proximity_exited` signals when influences cross object
boundaries. `burst_on_enter` (restart particles on proximity-enter) defaults OFF —
a follow-mouse influence would otherwise reset particles constantly as it crosses
the bounds.

For each tracked influence, `_update_follow()` also calls `_update_velocity()`,
which diffs the streamed position against `_prev_pos[instance_id]` (world units,
0 on the first frame seen) to get speed and mirrors it onto
`infl._tracked_speed` for the panel's status row; `_push_uniforms()` then uses
`infl.effective_signed_strength(speed)` instead of `infl.signed_strength()` when
packing the strength array, so InfluenceObject's `velocity_strength_amount`
takes effect without this controller ever touching the stored `strength`.
`_update_velocity()` also records the full velocity **vector** in
`_velocity[instance_id]` (world units/sec, for the direction-aware gestures below),
alongside the scalar `_speed`. `_update_velocity_burst()` is the rising-edge check
backing `velocity_burst` (speed crossing above `velocity_burst_threshold` restarts
nearby PolyParticles, via `_burst_was_over[instance_id]`). All four per-influence
dictionaries (`_prev_pos` / `_speed` / `_velocity` / `_burst_was_over`) are pruned
each frame for influences that stopped being tracked, and cleared in
`reset_defaults()`.

**Gesture layer.** `_update_gestures()` (last step of `_process`) recognizes three
gestures from the tracking data already computed this frame and emits a signal per
gesture, mirroring the `proximity_entered`/`proximity_exited` style. It operates on
the currently **tracked + enabled** influences (those with live `_prev_pos` /
`_velocity` — a follow-mouse influence has no mocap velocity, so it isn't a gesture
source). `push_pull(infl, direction)` (`_detect_push_pull`): the component of an
influence's velocity along the direction to the active camera crossing
`±push_pull_speed` — `direction` is `+1` toward the camera, `−1` away; rising-edge
via `_push_pull_dir[id]` (re-arms when the speed drops back under threshold, a
toward↔away flip re-fires). `clap(infl_a, infl_b)` (`_detect_clap`): every pair of
tracked influences whose spheres collide (surface gap `distance − rₐ − r_b` below
`clap_distance`), rising-edge per pair via `_clap_pairs["idA:idB"]`. `dwell(infl)`
(`_detect_dwell`): an influence held within `dwell_radius` of an anchor spot for
`dwell_seconds` — `_dwell_anchor`/`_dwell_time`/`_dwell_fired` accumulate the hold
and latch a single emit per episode (re-anchor + reset on leaving the radius). Each
detector prunes its own bookkeeping for influences no longer tracked, exactly like
the tracking dictionaries. The four thresholds (`clap_distance`, `push_pull_speed`,
`dwell_seconds`, `dwell_radius`) are `@export`ed and shown in a **Gestures** panel
section (so they serialize with the controller under `"auto_bind"`);
`reset_defaults()` restores them. **No consumers are wired yet** — the signals exist
for downstream effects (a clap burst, push-to-scatter, dwell-to-select) to connect
to, the way `_on_proximity_entered` consumes `proximity_entered`.

**Trajectory history.** `_update_history()` (run before `_push_uniforms` each frame)
keeps a shared ring buffer of every *active* influence's recent world-space path —
one `PackedVector3Array` per instance_id (`_history`), appended at a fixed
`sample_hz` cadence via `_history_accum` (framerate-stable, mirroring PolyTrails'
sampling) and capped at `ceil(history_seconds * sample_hz)` samples. The active set
comes from `_active_influences()` (enabled, strength > 0, capped at MAX_INFLUENCES),
now shared with `_push_uniforms`. Buffers for influences that go inactive are pruned
each frame, and `_history` is cleared in `reset_defaults()`. `get_influence_history(
instance_id) -> PackedVector3Array` (oldest → newest) is the public lookup so **any**
visualization can react to where an influence has *been*, not just where it is now;
`history_seconds` / `sample_hz` are exposed in a **Trajectory History** panel section
(serialized with the controller under `"auto_bind"`). Its first consumer:
`_push_uniforms` derives a per-active-influence "smear" vector (`hist[0] − hist[last]`,
pointing back along the path, padded to MAX_INFLUENCES) and hands it to every
`PolyMetaballs` via `set_influence_motion()` (special-cased in the push loop like the
`follow_influence` particle case) so blobs elongate into comet tails.

`auto_bind_rigid_bodies` (off by default) keeps InfluenceObjects in 1:1 sync with
whatever OptiTrack rigid bodies are currently streaming, for setups with several
tracked props. Each frame, while on, `_update_auto_bind()` reads
`OptiTrack.get_rigid_body_assets()` (guarded exactly like `_optitrack_pos` —
`get_node_or_null` + `has_method` + `is_connected_to_motive`, so it's a no-op
without the plugin) and: despawns any influence *it* previously auto-spawned
whose asset stopped streaming (`VisualizationManager.remove()`, a generalization
of `remove_selected()` that frees a specific object without touching the current
selection); then spawns one influence per streamed asset nothing already tracks
(`VisualizationManager.add_influence(false)` — the `false` skips the usual
select-on-add so a background auto-spawn doesn't steal panel focus), setting
`track_rigid_body = true` and `rigid_body_asset_id`, and copying
radius/strength/color from the first manually-created influence found (a
"template"; falls back to `InfluenceObject`'s own defaults if none exists).
Manually-created influences — and their own `track_rigid_body` assignments — are
never spawned or despawned by this. Spawning stops once total influence count
hits `MAX_INFLUENCES` (8), matching the shader's fixed-size influence arrays.
Auto-bound influences use the normal per-object `invert_x`/`invert_z`/
`map_to_wall`/`project_to_view` handling in `_optitrack_pos()` like any other
tracked influence — no special-casing needed. Turning the mode off just stops
further auto add/remove; influences it already spawned remain as ordinary,
manually-editable influences. Schema-driven like the other global modules
(`auto_bind_status()` backs a live "N bound" status row), serialized by
CompositionIO under `"auto_bind"`; `reset_defaults()` turns it off.

### GradientColormap
`Resource` wrapping a `Gradient` and baking it to a `GradientTexture1D`.
Presets: VIRIDIS (1), PINK_RED_WHITE (2), PURPLE_YELLOW (3), GREEN_TEAL (4).
Factory: `GradientColormap.create(Preset)`. Emits `changed` when the gradient
changes so dependent shaders refresh.

### AshimaNoise
Static-only CPU port of the Ashima 3D simplex noise (`snoise3`) that the spatial
shaders use. Lets CPU-animated geometry (PolyMesh's `animate_lattice`) match the
GPU-animated surface, which calls the identical `snoise` in the shader.

### OptiTrackSkeletonUtil
Static-only helper that resolves one named bone's world-space position from the
Dictionary `OptiTrack.get_skeleton_bone_data(asset_id)` returns (bone_name →
`[id, parent_id, position, rotation]`; see `optitrack_skeleton.gd`). Only the
root bone's position/rotation is already in world space — every other bone's is
relative to its parent — so `bone_world_position()` walks the hierarchy from the
root down to the target bone, composing a `Transform3D` at each step, and
returns its origin. Used by `InfluenceController._skeleton_pos()` to drive a
`track_skeleton_bone` influence, and by `InfluenceObject.skeleton_bone_position_status()`
for the panel's live readout.

### ParameterPanel
Auto-generates controls from `get_param_schema()` arrays. Schema format:

```gdscript
[
  { "title": "Section Name", "props": [
      { "name": "my_prop", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01 },
      { "name": "my_flag", "type": "bool" },
      { "name": "my_color", "type": "color" },
      { "name": "my_mode", "type": "enum", "options": ["A", "B", "C"] },
      { "name": "my_vec",  "type": "vector3" },
      { "name": "colormap","type": "colormap_preset" },
      { "name": "my_method", "type": "action", "label": "Do It", "hint": "..." },
  ]}
]
```

Supported types: `float`, `int`, `int_field`, `string`, `bool`, `color`, `enum`,
`vector3`, `colormap_preset`, `action`. `float`/`int` render sliders; `int_field`
renders a SpinBox (exact entry, e.g. an OptiTrack asset ID); `string` renders a
LineEdit (committed on Enter / focus-out). Sliders record undo on `drag_ended`;
booleans and enums record immediately. Colors record on `popup_closed`. An `action` prop
renders a button that calls `obj.<name>()` then refreshes the object's controls;
it stores no value and CompositionIO skips it during (de)serialization.

`colormap_preset` (`_add_colormap`) renders an OptionButton of the nine built-in
presets plus a trailing **"Custom…"** entry. Picking a preset assigns
`GradientColormap.create(preset)` as before; picking Custom seeds a fresh
`preset = CUSTOM` colormap from the currently-shown gradient and reveals an inline
editor below the dropdown — a live preview strip plus one row per stop (per-stop
`ColorPickerButton`, a draggable 0–1 offset `HSlider`, and a remove button
disabled at the two-stop minimum) and an **+ Add Stop** button. Edits mutate a
stable per-refresh model `[{off, col}, …]` (rows keep creation order) and rebake
`cm.gradient` from an offset-sorted copy via `_apply_custom_model`, so dragging a
stop past another never desyncs the rows; `set_gradient`'s `changed` signal
propagates to the object and re-bakes the shared preview texture in place. Because
the colormap stays `preset = CUSTOM`, CompositionIO serializes its literal
`offsets`/`colors` and `_decode_colormap` restores them on load (a CUSTOM preset
means `set_preset` won't overwrite the loaded gradient). Gradient-editor edits are
not routed through UndoHistory (see Known limitations).

Panel top-to-bottom: title → object selector → add/remove → preset/save/load/dup
→ capture/record → status line → hint bar → camera → scene → audio reactivity →
HUD logo → selection ring → LED wall → auto-bind rigid bodies → auto-bind skeleton
→ two-hand control → post FX → performance (render scale) → object sections.
Camera/scene/audio/hud/gizmo/wall/auto-bind/skeleton-bind/two-hand/postfx/perf are
global modules in a static area; managed-object controls render in `_object_host` below
them.

### HudLogo
`CanvasLayer` overlay showing a logo over the front of the view. Bundles the
OptiTrack white/black PNGs (`resources/logos/`) as presets via the `logo` enum,
plus a `custom_path` for any imported image (`import_logo()` action opens a file
dialog; external paths load through `Image.load_from_file`). Controls `corner`,
`size_scale`, `opacity`, `margin`. Sits at `layer = 0` (below the panel's
CanvasLayer, above the 3D view) and is NOT the CaptureManager's `ui_layer`, so it
stays visible in screenshots/recordings as a watermark. Schema-driven like
SceneEnvironment; serialized under `"hud"`. `custom_path` is a `"string"` schema
prop — it renders an editable text field and can also be set via the Import button.

Drop shadow (`shadow_enabled`, `shadow_color`, `shadow_offset_x/y`, `shadow_blur`):
a second TextureRect (`_shadow`) added before the logo rect so it renders behind.
Uses the same texture/size/stretch via `hud_shadow.gdshader`, which fills the
logo's alpha silhouette with `shadow_color` (the shadow is the logo's SHAPE in that
color, not a tint of its pixels), offset by `shadow_offset_*`. `shadow_blur`
Gaussian-blurs the silhouette alpha (radius in texels, `u_blur`; 0 = hard edge),
clamped to the rect bounds so it bleeds into the image's transparent padding.
`shadow_color.a` controls shadow strength; `opacity` fades both rects.

NOTE: the enum is `LogoCorner`, not `Corner` — `Corner` is a Godot built-in enum
and shadowing it is a parse error.

### CompositionIO
Stateless serializer. `serialize(manager, camera, scene=null, hud=null,
gizmo=null, wall=null, audio=null, influence_ctrl=null, postfx=null,
skel_bind=null, two_hand=null)` → Dictionary;
`apply(data, manager, camera, scene=null, hud=null, gizmo=null, wall=null,
audio=null, influence_ctrl=null, postfx=null, skel_bind=null, two_hand=null)` →
rebuilds from Dictionary. File I/O:
`save_json` / `load_json`. Encoding: colors → `[r,g,b,a]`,
Vector3 → `[x,y,z]`, enums → int, strings → as-is, colormaps → `{"preset": N,
"offsets": [], "colors": []}`. Camera, `scene` (SceneEnvironment), `hud` (HudLogo),
`gizmo` (SelectionGizmo), `wall` (WallConfig), `audio` (AudioReactor),
`influence_ctrl` (InfluenceController, under key `"auto_bind"`), `postfx`
(PostFX), `skel_bind` (SkeletonAutoBind, under key `"skeleton_bind"`), and
`two_hand` (TwoHandControl, under key `"two_hand"`) are each
serialized by walking their `get_param_schema()` via the shared
`_schema_to_dict` / `_dict_to_schema` helpers. Each managed object also stores
`position` + `rotation` (Euler degrees). On load, if a module is supplied but the
composition lacks its block, `reset_defaults()` runs first (white room / no logo /
ring off / default wall / audio off / auto-bind off / post FX off / skeleton
auto-bind off) — note `manager.clear_all()` (which runs before any module reset)
already frees any influences a previous auto-bind session spawned.

`apply` always sets the final state instantly; the *animated* preset/composition
glide is layered on top by `Main.apply_composition` (see below), which the panel
routes both the preset dropdown and the Load button through. CompositionIO itself
stays stateless and has no knowledge of the tween.

RenderScale is intentionally **not** a CompositionIO module — it's a machine
performance preference persisted to `user://settings.cfg`, so it must survive
composition/preset loads rather than reset with them (don't add it here).

### Main
Root coordinator (`Main.tscn`) — instantiates and wires every runtime system in
`_ready()`. Beyond wiring, it owns the animated composition transition:
`apply_composition(data)` snapshots the interpolatable state (camera
target/distance, SceneEnvironment `bg_color`/`bg_color2`/`bloom_intensity`, and
each managed object's float/color/vector3 params), runs `CompositionIO.apply`
(which sets everything to its final value and rebuilds the object list), then
tweens the snapshotted values from old→new over
`SceneEnvironment.transition_duration` on a single parallel `Tween` created on
Main (`SINE`/`EASE_IN_OUT`). Robustness: only `float`/`color`/`vector3` props
tween (ints/enums/bools/strings/colormaps are structural — they snap); surviving
object params are matched old→new by **slot index + type**, so add/remove/type
changes just keep the freshly-applied values and differing object counts never
error; `lock_background` skips the bg snapshot+tween; and `transition_duration`
= 0 short-circuits to a plain instant `apply`. A new load kills any still-running
transition tween. The ParameterPanel calls this via its `_main` reference (passed
into `panel.setup`), falling back to a direct `CompositionIO.apply` if unset.

### SceneEnvironment
`RefCounted` wrapper around the `WorldEnvironment.environment` resource, bound by
Main at startup via `bind()`. Exposes the background + bloom + fog through
`get_param_schema()` so they render in the panel (under the camera) and serialize
under the `"scene"` key. `bg_color` also drives `ambient_light_color` (dark
background → dark room) in every mode, so object lighting stays predictable
regardless of the backdrop. Bloom uses additive glow with a 0.7 HDR threshold, so
particles with `particle_brightness > 1` bloom.

Volumetric fog is exposed as a separate **"Fog"** schema section below bloom:
`fog_enabled` toggles Godot's built-in volumetric fog (Forward+ only) and
`fog_density` / `fog_albedo` / `fog_emission` / `fog_length` / `fog_gi_inject` map
straight onto the `Environment.volumetric_fog_*` properties in `_apply()`, pushed
every call exactly like the glow block. `fog_emission` is the key knob for the dark
LED-wall scenes — it makes the haze self-lit so it reads on a black backdrop with
no light hitting it. Fog is applied underneath glow (the scene is scattered by the
fog, then glow blooms the bright/emissive pixels), so it composites cleanly with
the neon bloom above rather than fighting it. Off by default; `reset_defaults()`
clears it (fog off, density 0.03, white albedo, no emission, length 64, no GI
inject) so a composition with no `"scene"` block loads clean.

`background_mode` (BackgroundMode enum) picks the backdrop:
- **COLOR** — flat `bg_color` room (`Environment.BG_COLOR`), the classic look.
- **NOISE** — an animated fractal-noise sky (`Environment.BG_SKY` + a `Sky` with
  `background_noise.gdshader`) blending `bg_color` ↔ `bg_color2`, with
  `noise_scale` / `noise_speed` / `noise_contrast`. The sky shader animates off
  its own `TIME` (the `Sky` runs `PROCESS_MODE_REALTIME`), so no per-frame CPU push.
- **SKYBOX** — a panorama image from `skybox_path` via a `PanoramaSkyMaterial`
  (`PROCESS_MODE_QUALITY`). `_load_skybox()` mirrors HudLogo's external-image
  handling (res:// / user:// through the loader, OS paths via
  `Image.load_from_file`); an empty/invalid path falls back to COLOR so the
  background is never a black void. `skybox_path` is a `string` schema prop
  (editable text field), and the **Load Skybox…** action (`import_skybox()`) opens
  a file browser that sets the path and switches to SKYBOX. Since SceneEnvironment
  is `RefCounted`, the `FileDialog` is parented to a host node passed to `bind()`
  by Main (`bind(env, self)`).
- **AURORA** — animated aurora-borealis curtains (`aurora_sky.gdshader`, also
  `BG_SKY` + realtime `Sky`) over `bg_color` (night sky), tinted by `bg_color2`
  (dominant curtain color, shifting to blue higher and magenta at the ray tips).
  Reuses `noise_scale` / `noise_speed` / `noise_contrast` as the aurora's
  scale / shimmer / intensity. The Aurora preset uses it (black sky + green
  curtains + bloom).

The `Sky` and its two materials (noise `ShaderMaterial`, `PanoramaSkyMaterial`)
are created lazily and reused across mode switches. `reset_defaults()` resets all
of the above (COLOR / white room / no sky / no bloom) so a composition with no
`"scene"` block loads clean.

`lock_background` and `transition_duration` are live **session preferences**
(`"serialize": false`, not reset by `reset_defaults`, so they persist across
preset switches within a session). `lock_background` keeps the current backdrop
across loads (CompositionIO.apply skips the `"scene"` restore while it's on).
`transition_duration` (default 0.8s, 0 = instant) is read by
`Main.apply_composition` to time the animated preset/composition glide — see the
Main section below. Both render in the panel's Scene section but never save.

### UndoHistory
Thin wrapper around Godot's built-in `UndoRedo`. `record_property(obj, prop,
old_val, new_val)` commits an action with `execute=false` (value already applied).
`history_changed` signal fires after every undo/redo; Main connects it to
`panel.show_object(selected)` to refresh controls.

`record_object_add(manager, obj)` / `record_object_remove(manager, obj)` make
object add/remove undoable (both call the shared `_record_object`). The do/undo
callables re-materialize the object from a `CompositionIO.serialize_object`
snapshot on the create side and free it via `manager.remove()` on the destroy
side; because an undone-then-freed instance can't be referenced again, the
callables share a one-slot `holder` (the live instance, or null) and a one-slot
`snapshot` (re-captured on every destroy, so edits made between an add and a later
undo survive). An add commits with `execute=false` (the caller already spawned the
object; only redo replays the create), a remove commits with `execute=true` (the
destroy performs the actual removal now). Restoring a removed object reselects it;
undoing an add lets `remove()` pick a sensible neighbor. The manager's user-facing
`add_*`/`remove_selected` are the only callers.

### CaptureManager
`capture(scale)` hides the UI layer, awaits one frame for a clean render, grabs
the viewport image, optional Lanczos upscale, saves to `user://screenshot_*.png`.
`start_recording(fps)` / `stop_recording()` write numbered PNGs to
`user://sequence_*/frame_00000.png`.

### SelectionGizmo
`MeshInstance3D` using `ImmediateMesh` to draw a glowing ring in the XZ plane
under the selected object. Ring radius matches the object's bounding extent.
Skips `InfluenceObject` (which already draws its own radius sphere). Gated by an
`enabled` toggle that is **off by default** — it is a schema-driven global module
(like SceneEnvironment/HudLogo) serialized under `"gizmo"`, so loading any preset
(which carries no `"gizmo"` block) resets it off. Toggle it on via the panel's
"Selection Ring" section.

### WallConfig
`RefCounted` schema-driven global module (like SceneEnvironment) describing the LED
wall the app renders onto, created by Main and serialized under `"wall"`. Holds the
wall's physical size (`physical_width`/`physical_height`, metres), pixel
`pixel_width`/`pixel_height` (`int_field`s), and physical `origin` (wall centre in
OptiTrack metres). `apply_resolution()` (an `action`) resizes the window to the
pixel resolution so the render maps 1:1 to the panels — it first drops to windowed
mode (`window_set_size` is ignored while maximized/fullscreen) and sets the root
`content_scale_size` (the project's `canvas_items` stretch otherwise keeps the old
2D base and just scales it, so the render never actually matches the new size).
`fit_to_monitor()` (an `action`) instead fills the window's current monitor: it
goes (borderless) fullscreen on that screen (`window_get_current_screen` /
`screen_get_size`) and sets `content_scale_size` to the monitor resolution so the
viewing space fills it 1:1. `physical_to_uv(metres)`
converts a real-world position to a normalized screen coord (X→horizontal,
Y→vertical) — used by `InfluenceController._wall_to_view` to place a `map_to_wall`
influence at the tracked object's real spot on the rendered wall (physical metres →
screen UV → unproject onto the view plane). Like the other global modules, presets
carry no `"wall"` block, so loading one runs `reset_defaults()` (1920×1080, 3×2 m).

### RenderScale
`RefCounted` schema-driven **Performance** module — the proper replacement for the
old ad-hoc "half resolution" hack. Drives the root viewport's `scaling_3d_scale`
(`render_scale`, 0.25–1.0) and `scaling_3d_mode` so the 3D scene renders at a
fraction of the window while the 2D UI stays full-resolution (Godot always renders
2D at native res, so the panel/logo stay crisp; screenshots capture the upscaled
result). Reaches the viewport through `Engine.get_main_loop().root` like WallConfig
— no host bind needed. `upscale_mode` picks Bilinear or FSR 1.0; FSR needs the
Forward+/Mobile renderer (`RenderingServer.get_current_rendering_method()` via
`_fsr_supported()`) and only engages while actually upscaling (`render_scale < 1`),
else it falls back to Bilinear. `auto_scale` mirrors PolyParticles' `auto_budget`:
`update(delta)` (called from `Main._process`) samples FPS once per second over a
5-sample window and `_apply_auto(avg)` hill-climbs `render_scale` with asymmetric
hysteresis (drop below 0.92×target, raise only above 1.12×) to hold `target_fps`
without oscillating. `scale_status()` backs a live "Effective" panel row (3D
buffer size + active upscaler).

Unlike every other module this is a **machine preference, not composition state**:
it persists to `user://settings.cfg` (`ConfigFile`, `[performance]` section) via
`_save()` on every setter and `load_settings()` in `_init()`, and is deliberately
**not** threaded through CompositionIO — so loading a preset authored elsewhere
never forces a render scale onto a slower box (the Mac that motivated this). Main
creates it after WallConfig, calls `apply()`, passes it to `panel.setup(...)`, and
ticks `update(delta)`.

### AudioReactor
`RefCounted` schema-driven global module (like SceneEnvironment/WallConfig), created
by Main and serialized under `"audio"`. Taps a Godot `AudioEffectSpectrumAnalyzer`
and reduces it each frame (`update(delta)`, called from `Main._process`) to three
normalized bands — `bass`/`mid`/`treble` (20–250 Hz / 250–4000 Hz / 4000–12000 Hz,
dB-normalized over -60..0dB, exponentially smoothed by `smoothing`, each with its own
`*_gain`) — plus a `beat` pulse: a rising edge when `bass` exceeds
`beat_sensitivity ×` its own rolling average, decaying back to 0. `enabled` is
**off by default** so the app never opens a mic input uninvited. `input_source`
picks where the analyzer taps: `SYSTEM_MIC` creates a muted private `"AudioReactor"`
bus and an `AudioStreamPlayer` running an `AudioStreamMicrophone` stream routed to
it — point the OS default input device at a loopback source (BlackHole / Stereo
Mix / equivalent) to react to whatever's playing on the system; `MASTER_BUS`
instead analyzes Poly-Vis's own `"Master"` bus (whatever the app itself plays).
Both paths lazily attach the spectrum-analyzer effect once and reuse it across
mode switches. `bind(host)` parents the mic `AudioStreamPlayer` (RefCounted can't
add children itself) — mirrors `SceneEnvironment.bind(env, host)`. Like the other
global modules, presets carry no `"audio"` block, so loading one runs
`reset_defaults()` (audio off). `level_status()` backs a `"status"` schema row for
a live bass/mid/treble/beat readout in the panel.

`VisualizationManager.audio_reactor` holds the instance (set once by Main) and
`_register()` wires it onto every new `PolyParticles` or `PolyBoids` as
`obj.audio_reactor` — the
current consumers. Both expose `brightness_audio_band`
(None/Bass/Mid/Treble) and `brightness_audio_amount`: when a band is selected,
`_process` multiplies `particle_brightness` by `(1 + level * amount)` straight into
the `u_particle_brightness` shader uniform each frame, without touching the stored
`particle_brightness` value — `level` is 0 whenever no band is picked or the
reactor is off/silent, so it's a no-op with no audio present. This is the pattern
for adding audio reactivity to further parameters: read `audio_reactor.bass` /
`.mid` / `.treble` (or `.beat`) in the consuming object's own `_process`.

### PostFX
`RefCounted` schema-driven global module (like SceneEnvironment/WallConfig/
AudioReactor), created by Main and serialized under `"postfx"`. A full-screen
post-processing pass: `bind(host)` creates a `CanvasLayer` (at `layer = 0`,
above the 3D view and below the UI panel at layer 1) holding a `BackBufferCopy`
(`COPY_MODE_VIEWPORT`, feeds the 3D render into the screen texture) then a
`ColorRect` running `poly_postfx.gdshader`, and parents it to `host` (RefCounted
can't add children itself — mirrors `SceneEnvironment.bind`). Bound BEFORE
HudLogo in `Main._ready`, so the effect processes the 3D view and the logo
overlays on top un-graded. Like HudLogo the layer is NOT the CaptureManager's
`ui_layer`, so the effect is baked into screenshots/recordings while the UI
(above it) is hidden during capture and never post-processed. Effects: `vignette`
(amount + softness), `chromatic aberration` (radial R/B split), `film grain`
(animated, off `TIME`), and an optional color grade (`color_grade_enabled` +
contrast/saturation/tint). Every effect is identity at its zero/default, so the
master `enabled` toggle (which just shows/hides the layer, off by default) leaves
the image untouched until a value is raised. Setters re-push all uniforms via
`_apply()`. Chose contrast/saturation/tint over a LUT path for a self-contained
grade. Like the other modules, presets carry no `"postfx"` block, so loading one
runs `reset_defaults()` (all effects off).

### SkeletonAutoBind
`RefCounted` schema-driven global module (like WallConfig/AudioReactor), created
by Main (`skel_bind`, `setup(manager)`) and serialized under `"skeleton_bind"`.
The skeleton counterpart to `InfluenceController.auto_bind_rigid_bodies`: while
`enabled`, `update()` (called each frame from `Main._process`) keeps one
`InfluenceObject` bound to each named bone of a streamed OptiTrack skeleton. It
reads `OptiTrack.get_skeleton_bone_data(skeleton_asset_id)` through
`_live_bones()`, guarded exactly like `InfluenceController._skeleton_pos`
(`get_node_or_null("/root/OptiTrack")` + `has_method` + `is_connected_to_motive`,
then a per-bone presence check), so it's a no-op without the plugin, on
non-Windows, with Motive/the asset offline, or a bone not streaming. Each frame it
**despawns** (`VisualizationManager.remove()`) any influence it spawned whose bone
stopped streaming or left the list, then **spawns** one influence per wanted bone
that is streaming and nothing already tracks (`spawn_influence(false)` — undo-free,
matching `_update_auto_bind`, so the background spawn stays out of the undo history
and doesn't steal panel selection), setting `track_skeleton_bone = true` +
`skeleton_asset_id` + `skeleton_bone_name` and copying radius/strength/color from a
template (the first manually-created influence, else `InfluenceObject` defaults).
Manually-created influences — and their own `track_skeleton_bone` assignments — are
never spawned or despawned by this; a bone is "claimed" (left alone) if any
influence already tracks it on the same `skeleton_asset_id`. Spawning stops once the
total influence count hits `MAX_INFLUENCES` (8). `bone_names` is a `string` schema
prop holding a comma-separated bone list (default `"Head, LHand, RHand, LFoot,
RFoot"`), parsed by `_bone_list()` (trimmed, de-duplicated, blanks dropped);
`skeleton_asset_id` uses the `int_field` control. `bound_status()` backs a live "N
bound" status row. Like the other global modules, presets carry no
`"skeleton_bind"` block, so loading one runs `reset_defaults()` (off).

### TwoHandControl
`RefCounted` schema-driven global module (like WallConfig/AudioReactor), created by
Main (`two_hand`, `setup(manager, scene_env)`) and serialized under `"two_hand"`.
While `enabled`, `update()` (called each frame from `Main._process`) measures the
distance between the **two nearest enabled tracked influences** (`track_rigid_body`
or `track_skeleton_bone`; the closest pair when more than two exist, −1 if fewer
than two), normalizes it over `[min_distance, max_distance]`, expands that 0..1 into
`[output_min, output_max]`, and drives a chosen `target`: `Bloom` (scene glow),
`Metaball Radius` / `Cloth Amplitude` (the selected `PolyMetaballs` / `PolyCloth`),
or `Global Scale` (uniform scale on the selected `Node3D`). Application is
**non-destructive, exactly like the audio-band pattern** — it writes the *live*
representation (`SceneEnvironment.env.glow_intensity`, the object's shader uniform
`u_blob_radius` / `u_anim_amplitude` via its `_mat` / `_surface_mat`, or the node
transform) and never the stored/serialized parameter, so the modulation is invisible
to CompositionIO and reverts the instant it disengages. `_release()` returns the live
value to the authored one (re-derived from the untouched stored value, or a cached
base scale) whenever the control is disabled, the target/selection changes, or
`reset_defaults()` runs — and only `Global Scale` needs the cached base since scale
isn't a schema param. A `distance_status()` row shows the live distance → mapped
value. Presets carry no `"two_hand"` block, so loading one runs `reset_defaults()`
(off, releasing any override first).

### InputManager
`_unhandled_key_input` handler. Delegates to VisualizationManager, panel, camera,
and UndoHistory. Full shortcut list in the script header comment.

### BuiltInPresets
Const dictionary of CompositionIO-compatible scenes (Default, Neon Rain, Muted
Rain, Petal Storm, Draped Silk, Sculpted Drape, Glacier Drape, Dune Drape, Crystal
Lattice, Lava Flow, Aurora, Void Sphere, Ribbon Chase, Merging Blobs). Applied by the preset dropdown in the
panel. Neon Rain ships a `"scene"` block (dark room + bloom) and stacks three
PolyParticles layers — palette-colored disc rain, a `follow_influence` spark
fountain trailing the cursor, and downward Streak rain — plus a hidden
follow-mouse influence. Muted Rain is a Neon Rain variant: the same three-layer
structure but denser/finer (higher counts, smaller `particle_size`, more
`flow_scale` detail) with a dusty desaturated palette and low brightness/bloom. Aurora also ships a `"scene"` block: a black night sky in
AURORA background mode (green curtains) with bloom, behind its turbulent
green-teal particle field. Draped Silk, Sculpted Drape, Glacier Drape,
and Dune Drape are the PolyCloth showcases, each pairing a warm colormap with a
contrasting `cool_color` for the two-tone facet split (Draped/Sculpted: pink +
periwinkle, Glacier: teal + amber, Dune: purple-yellow + blue). Draped Silk,
Glacier, and Dune are the calm variants — broad folds, low `fold`/`warp`, moderate
`curvature_amount`. All four use `curl_amount` (0.5–0.85) to roll the sheet into a
significant open C / scroll. Dune Drape stacks two cloth sheets (the second `rotation`d ~80°
about X and offset up/back) so they cross at an angle for a layered composition.
Sculpted Drape is the dramatic one: high `amplitude`/`warp`/
`curvature_amount` and fine `resolution` give the heavily-crumpled, ribbon-like
flowing form whose folds arc apart to reveal the white room through the gaps
between them, plus `hole_amount` punched through the sheet for torn-fabric gaps.
Ribbon Chase is the PolyTrails showcase: ten rainbow ribbons chasing a hidden
follow-mouse influence over a dark room with bloom. Merging Blobs is the
PolyMetaballs showcase: two hidden influences (one static, one follow-mouse) over
a dark room with bloom — drag the cursor into the static blob to fuse them.

---

## Shader conventions

### polymesh_deform.gdshader (spatial)
`render_mode cull_disabled` (double-sided) so folded high-amplitude surfaces
don't reveal the background through their folds; the fragment stage flips the
flat normal via `FRONT_FACING`. The vertex `snoise` is mirrored on the CPU by
`AshimaNoise.snoise3` for `animate_lattice`. Uniforms set by PolyMesh setters
each frame / on property change:

| Uniform | Set by |
|---|---|
| `u_time` | `_process` every frame |
| `u_base_color`, `u_roughness`, `u_metallic` | `_build_solid_surface` |
| `u_anim_amplitude/frequency/speed` | `_update_anim_uniforms` |
| `u_use_colormap`, `u_colormap`, `u_color_source`, `u_color_range` | `_apply_color_and_polish` |
| `u_posterize`, `u_posterize_steps` | `_apply_color_and_polish` |
| `u_rim_strength/power/color`, `u_translucency` | `_apply_color_and_polish` |
| `u_influence_count`, `u_influence_pos[]`, `u_influence_radius[]`, `u_influence_strength[]`, `u_influence_color[]` | `set_influences()` via InfluenceController |

### poly_voronoi.gdshader (spatial)
PolyVoronoi's fracture shader — `render_mode cull_disabled, diffuse_burley,
specular_schlick_ggx`, same flat-shading (face normal from `dFdx`/`dFdy`, flipped
by `FRONT_FACING`) and colormap / posterize / contrast / rim / `u_influence_*`
conventions as `polymesh_deform`. The geometry is baked with per-triangle cell data
(PolyVoronoi.gd), so the vertex stage reads the cell centroid from `CUSTOM0.xyz` and
cell id from `CUSTOM0.w`, evaluates the influence falloff once at the cell centre in
world space (`pow(fall, u_gap_falloff)`), and translates the vertex outward along
`normalize(CUSTOM0.xyz)` by `push * u_shatter_amount` — every vertex of a cell gets
the same centre + push, so cells separate rigidly at their seams. `color_source` 3
= flat `v_cellid` (Voronoi mosaic), 4 = `v_shatter` (crack amount). No `u_time` /
animation.

### poly_lightfield.gdshader (spatial)
PolyLightField's LED-cell shader — `render_mode unshaded, cull_disabled`, drawn on
a MultiMesh (one quad per cell). All response is per-cell in the **vertex** stage:
it reads the cell's world position from the MultiMesh instance origin
(`MODEL_MATRIX * vec4(0,0,0,1)`) and the shared `u_influence_*` arrays, accumulates
`pow(1 - smoothstep(0, radius, d), u_falloff) * |strength|` over the influences
(strongest sets the lit intensity, contributions weight the tint color), adds an
idle shimmer from the per-cell phase in `INSTANCE_CUSTOM.x` (`u_idle_brightness`
floor, `u_shimmer_*`), and outputs `colormap(intensity) * intensity` as both ALBEDO
and EMISSION so bright cells bloom. No CPU per-frame work — `set_influences()` only
pushes uniforms. This and the mesh nodes' shaders are `spatial`; the influence
convention is identical (fixed size 8), only here strength magnitude drives
brightness rather than displacement.

### particle_flow.gdshader (particles)
Similar set — all pushed via `_mat.set_shader_parameter()`. Curl-noise flow
field is divergence-free; `u_turbulence` scales the curl acceleration.
Influence fields attract (+) or accelerate particles away (−). Color priority in
`process()`: `u_palette[6]` (when `u_palette_count > 0`, flat per-particle pick via
the seed `CUSTOM.x`) → colormap → `u_color_a`/`u_color_b` lerp; then influence
tint, then `u_particle_brightness`.

### poly_boids.gdshader (particles)
PolyBoids' flocking motion — same `shader_type particles` scaffolding as
`particle_flow` (identical `start()`, emitter shapes, `snoise`/`curl_noise`, hash
RNG, and color/palette/influence blocks) but `process()` replaces the flow steer
with the three boid rules approximated from shared fields (no cross-particle reads
are possible): `curl_noise(pos / u_neighbor_radius)` for **alignment**,
`grad_noise` of a low-freq field for **cohesion**, `-grad_noise` of a high-freq
field for **separation**, summed by `u_alignment`/`u_cohesion`/`u_separation`,
added to VELOCITY and clamped to `u_max_speed` (with `u_drag` damping and
`u_wander_speed` scrolling the fields). `u_influence_strength` is signed the same
way — `+` accelerates toward (attractor), `−` away (predator). Unlike
`particle_flow`'s Z-spin, the TRANSFORM basis is rebuilt each frame with the mesh's
`+Y` axis along VELOCITY so elongated shapes point where the boid is heading.

### polycloth.gdshader (spatial)
PolyCloth's surface shader. Shares the colormap / posterize / contrast /
brightness / rim / influence uniform conventions with `polymesh_deform`, but:
animated displacement and influence dents ride along world-up (Y) instead of a
radial direction (coherent on a plane); color decisions use the baked
object-space normal varying `v_face_n` (camera-stable), while lighting uses the
derivative normal. Adds `u_cool_color`/`u_cool_strength`/`u_cool_dir` for the
warm/cool facet split, and reads baked height-noise + fold magnitude from `UV2`.

### poly_trails.gdshader (spatial)
PolyTrails' ribbon shader — `render_mode cull_disabled, unshaded, blend_mix,
depth_draw_never`. Shares the colormap (`u_colormap`/`u_use_colormap`/
`u_base_color`) and influence (`u_influence_*`, fixed size 8) conventions with
the mesh/cloth shaders, but the geometry is a CPU-built per-frame `ImmediateMesh`
so the shader only colors it: it samples the colormap by the length param `t`
(baked into `UV.x` by the mesh builder, 0 tail → 1 head), tints toward a nearby
influence's color by proximity (`u_influence_tint`), and fades `ALPHA =
pow(t, u_fade) * u_opacity` so the tail dissolves. `u_brightness > 1` blooms.

### poly_metaballs.gdshader (spatial)
PolyMetaballs' raymarched SDF shader — `render_mode cull_front, diffuse_burley,
specular_schlick_ggx, depth_draw_opaque`. Rendered on a proxy box (back faces),
it sphere-traces `map(p)` = the `smin` union of one sphere per influence from
`CAMERA_POSITION_WORLD` toward the fragment's world position (passed as a
varying, since `NODE_POSITION_WORLD` is vertex-only — `v_center` is likewise a
varying). Misses `discard`; hits write `DEPTH` (`PROJECTION_MATRIX *
VIEW_MATRIX * hit`) and a gradient normal (converted to view space for the
built-in lighting). Reuses the same colormap / posterize / contrast / rim /
influence-tint uniforms as `polymesh_deform`. Cost knobs: `u_max_steps`
(`quality`) and `u_surface_eps`; `u_max_dist` is derived from `bounds`. When
`u_motion_stretch > 0`, `map()` elongates each sphere along `u_influence_motion[i]`
(the influence's recent-path smear vector from InfluenceController's trajectory
buffer) by sweeping the centre over `[0, len]` — a one-sided capsule (comet tail),
zero-length motion left untouched.

### poly_strands.gdshader (spatial)
PolyStrands' blade-field shader — `render_mode cull_disabled, diffuse_burley,
specular_schlick_ggx` (thin double-sided blades; the fragment stage flips the
baked normal via `FRONT_FACING`). The field geometry is baked on the CPU
(PolyStrands.gd); this shader only animates it in the vertex stage. It reads each
vertex's height from `UV.y` and its blade root from `UV2`, reconstructs the root's
world position via `MODEL_MATRIX` (world-space combing/sway, like polycloth), then
adds an idle wind `sway` (two `snoise` samples) plus per-influence combing — bend
toward (`+u_influence_strength`) / away (`−`) each root, `smoothstep` falloff over
`u_influence_radius`, weighted `t²` toward the tip and divided by `u_stiffness` —
displacing `VERTEX.xz` with a slight `VERTEX.y` droop. Shares the same colormap /
posterize / contrast / rim / `u_influence_*` uniforms as `polymesh_deform` /
`polycloth`; color is `u_colormap` sampled by a per-blade meadow field (shaded
base→tip) when enabled, else the `u_base_color`→`u_tip_color` gradient.

### poly_postfx.gdshader (canvas_item)
PostFX's full-screen pass. Reads the 3D render via `hint_screen_texture` (fed by
the module's `BackBufferCopy`) and re-outputs it with vignette, chromatic
aberration (radial R/B channel offset), film grain (animated off `TIME`, sized by
`SCREEN_PIXEL_SIZE` so it's resolution-independent), and an optional grade
(contrast around mid-grey → saturation → tint multiply). Each block is gated so
its zero/default is identity. This is the only `shader_type canvas_item` shader
in the project (the rest are `spatial`).

---

## How to add a new visualization type

1. Create `scripts/MyThing.gd` extending an appropriate Node3D subclass.
2. Implement `get_param_schema() -> Array` (same format as above).
3. Implement `set_influences(count, positions, radii, strengths, colors)` if
   you want influence-field reactions.
4. Add a factory method and `_type_label` case in `VisualizationManager`.
5. Add a `"+ MyThing"` button in `ParameterPanel._build_base()`.
6. Add a `"MyThing"` branch in `CompositionIO.create_object()`.

## How to add a new parameter to an existing type

1. Declare `@export var my_param: float = default: set = set_my_param`.
2. Write `set_my_param(v)` — call the cheapest update path
   (`_apply_color_and_polish`, `_update_anim_uniforms`, or full `rebuild()`).
3. Add an entry to the appropriate `get_param_schema()` section.
4. If the parameter drives a shader uniform, push it in the setter via
   `_surface_mat.set_shader_parameter("u_my_param", v)`.

No changes to ParameterPanel or CompositionIO are needed — both are driven
entirely by the schema.

---

## Serialization format (v1)

```json
{
  "version": 1,
  "objects": [
    {
      "type": "PolyMesh",
      "position": [0.0, 0.0, 0.0],
      "rotation": [0.0, 0.0, 0.0],
      "params": {
        "subdivisions": 3,
        "colormap": { "preset": 1, "offsets": [], "colors": [] },
        "base_color": [0.85, 0.2, 0.45, 1.0]
      }
    }
  ],
  "scene": { "bg_color": [0.02, 0.02, 0.05, 1.0], "bloom_enabled": true, "bloom_intensity": 1.2, "fog_enabled": true, "fog_density": 0.04, "fog_albedo": [1.0, 1.0, 1.0, 1.0], "fog_emission": [0.1, 0.3, 0.6, 1.0], "fog_length": 64.0, "fog_gi_inject": 0.0 },
  "hud": { "enabled": true, "logo": 1, "corner": 2, "size_scale": 0.16, "opacity": 1.0, "shadow_enabled": true, "shadow_color": [0.0, 0.0, 0.0, 0.5], "shadow_offset_x": 8.0, "shadow_offset_y": 8.0, "shadow_blur": 0.0 },
  "wall": { "physical_width": 3.0, "physical_height": 2.0, "pixel_width": 1920, "pixel_height": 1080, "origin": [0.0, 0.0, 0.0] },
  "audio": { "enabled": true, "input_source": 0, "smoothing": 0.8, "bass_gain": 1.0, "mid_gain": 1.0, "treble_gain": 1.0, "beat_sensitivity": 1.3 },
  "auto_bind": { "auto_bind_rigid_bodies": false },
  "postfx": { "enabled": true, "vignette_amount": 0.4, "vignette_softness": 0.5, "aberration_amount": 0.2, "grain_amount": 0.08, "grain_speed": 1.0, "color_grade_enabled": true, "grade_contrast": 1.1, "grade_saturation": 1.2, "grade_tint": [1.0, 0.95, 0.9, 1.0] },
  "skeleton_bind": { "enabled": false, "skeleton_asset_id": 1, "bone_names": "Head, LHand, RHand, LFoot, RFoot" },
  "two_hand": { "enabled": false, "min_distance": 0.2, "max_distance": 3.0, "target": 0, "output_min": 0.0, "output_max": 2.0 },
  "camera": { "target": [0.0, 0.0, 0.0], "distance": 6.0 }
}
```

The `"scene"`, `"hud"`, `"wall"`, `"audio"`, `"auto_bind"`, `"postfx"`,
`"skeleton_bind"`, and `"two_hand"` blocks
are optional; when absent on load the environment resets to the default white room
(no bloom), the logo turns off, the wall resets to its default dimensions, audio
reactivity turns off, auto-bind rigid bodies turns off, post FX turns off,
skeleton auto-bind turns off, and two-hand control turns off.
Each object stores `"position"` and `"rotation"` (Euler degrees) alongside its
schema `params`; `rotation` is optional (older comps without it load unrotated).
Only parameters present in `get_param_schema()`
are serialized. Missing keys
on load keep the object's GDScript defaults. Colormap `preset` values map to
`GradientColormap.Preset` enum (CUSTOM=0, VIRIDIS=1, PINK_RED_WHITE=2,
PURPLE_YELLOW=3, GREEN_TEAL=4). Empty `offsets`/`colors` arrays means "use the
preset's built-in gradient."

---

## OptiTrack motion capture (addons/optitrack_plugin)

Third-party GDExtension (NatNet/Motive client) under `addons/optitrack_plugin/`.
Registered in `project.godot`: the `OptiTrack` autoload (`optitrack.gd extends
MotiveClient`) plus the editor sub-plugins (control panel + custom node types).
Windows x86_64 **debug** DLL only (`bin/`), so it streams when run from the
editor; an exported release build would need a release DLL not shipped here.

Autoload API used by Poly-Vis (all defensive — see `_optitrack_pos` /
`_skeleton_pos`): `is_connected_to_motive() -> bool`,
`get_rigid_body_pos(asset_id) -> Vector3` (already in Godot space),
`get_rigid_body_rot(asset_id) -> Quaternion`, `get_rigid_body_assets() ->
Dictionary` (asset id → Motive name), `get_skeleton_assets() -> Dictionary`
(asset id → Motive name), `get_skeleton_bone_data(asset_id) -> Dictionary`
(bone name → `[id, parent_id, position, rotation]` — position/rotation are
world-space only for the root bone, parent-relative for every other bone; see
`OptiTrackSkeletonUtil` above), `set_server_address/set_client_address/
set_multicast`, `connect_to_motive` / `disconnect_from_motive`.

Integration: an `InfluenceObject` with `track_rigid_body = true` has its world
position driven by `OptiTrack.get_rigid_body_pos(rigid_body_asset_id) +
track_position_offset`, evaluated each frame in `InfluenceController._update_follow`
(priority over `follow_mouse`). One with `track_skeleton_bone = true` instead has
its position driven by `OptiTrackSkeletonUtil.bone_world_position()` on
`OptiTrack.get_skeleton_bone_data(skeleton_asset_id)[skeleton_bone_name]`
(`InfluenceController._skeleton_pos`), taking priority over both
`track_rigid_body` and `follow_mouse`. Both lookups are guarded with
`get_node_or_null("/root/OptiTrack")` + `has_method` + connection checks (plus,
for skeletons, an asset/bone-presence check), so the app runs normally with the
plugin absent, on non-Windows, or with Motive/the given asset or bone offline
— the influence just holds position.

The influence's "OptiTrack" panel section (`get_param_schema`) carries the
connection settings too, so they save/load with the composition: `optitrack_server_ip`
/ `optitrack_client_ip` (`string` fields, default `127.0.0.1`), `optitrack_multicast`
(bool — on = multicast, off = unicast), and a **Connect / Reconnect** action
(`reconnect_optitrack()`) that pushes those three to the autoload and reconnects
(all guarded → no-op without the plugin). `rigid_body_asset_id` uses the `int_field`
(SpinBox) control for exact entry. `project_to_view = true` flattens the streamed
position onto a camera-facing plane through the world origin
(`InfluenceController._project_to_view`), so the rigid body drives the influence in
screen space with locked depth. `map_to_wall = true` (takes priority over
`project_to_view`) instead maps the physical position through `WallConfig` — real
metres → wall pixel → view plane (`_wall_to_view`) — so the influence lines up with
the object's actual position in front of the LED wall; calibrate via the panel's
**LED Wall** section (physical size, resolution, origin). `invert_x`/`invert_z`,
`track_position_offset`, `project_to_view`, and `map_to_wall` all apply equally
to `track_skeleton_bone` (via the shared `_apply_tracking_transform` helper), so
a skeleton-driven influence can be wall-mapped or view-locked exactly like a
rigid-body one. The editor's OptiTrack dock + `optitrack_settings.tres` remain
the other place to configure the connection.

`skeleton_asset_id` (`int_field`) + `skeleton_bone_name` (`string`, e.g. `"Hip"`,
`"RHand"`, `"Head"` — must match a key of `get_skeleton_bone_data`) pick the
joint; **Skeleton Status** / **Bone Position** status rows mirror the rigid-body
ones for live debugging. To use: open in the editor, add an `OptiTrackSkeleton`
node for the asset (or otherwise ensure Motive is streaming it), set the
influence's IPs / transport and click Connect / Reconnect (or use the OptiTrack
dock), set `skeleton_asset_id` + `skeleton_bone_name` (or `rigid_body_asset_id`
for rigid-body tracking) to a streamed asset/bone, run.

---

## Performance notes

- **PolyMesh rebuild cost** scales as O(4^subdivisions). subdivision 4 = 1280
  triangles (fast); subdivision 6 = 20 480 (slow, avoid at runtime).
- **LOD** reduces the rebuild cost for distant objects. Enable with
  `lod_enabled = true` and tune `lod_dist1` / `lod_dist2`.
- **PolyParticles** GPU cost scales linearly with `count`. Default 4 000 is
  lightweight; 50 000 may struggle on integrated graphics. Enable `auto_budget`
  to let the system scale automatically.
- **Lattice (MultiMesh)** cost scales with edge count → O(4^subdivisions).
  Use SOLID render mode in production; WIREFRAME and SOLID_WIREFRAME are for
  authoring.
- **Influence uniforms** are pushed every frame regardless of whether any
  influences are present. Cost is negligible (array upload), but if you add
  more shader uniforms mirror the fixed-size arrays pattern (always pad to
  `MAX_INFLUENCES = 8`).
- **CaptureManager recording** writes PNG per frame synchronously on the main
  thread. For high particle counts or high subdivision keep FPS expectations
  realistic; the budget system will reduce particle count automatically.
- **RenderScale** (Performance section) is the front-line knob for GPU-bound
  scenes — lowering `render_scale` cuts 3D fill cost quadratically (0.5 = ¼ the
  3D pixels) while the UI stays sharp. Prefer this on the LED wall over dropping
  object detail. Enable `auto_scale` to hold a target FPS hands-off. FSR 1.0 is
  the recommended upscaler on Forward+; it silently falls back to bilinear on the
  GL Compatibility backend (and web exports that use it).

---

## Known limitations / future work

- Undo/redo covers parameter sliders, booleans, enums, colors, and object
  add/remove (deleting an object then undo restores its full params + transform
  from a CompositionIO snapshot). Duplication is not undoable (it routes through
  the undo-free `spawn_*` path).
- LOD rebuilds the lattice MultiMesh on level change; that rebuild is
  synchronous and may cause a single-frame hitch at transition distance.
- Gradient-editor edits (add/remove/move/recolor a custom stop) are not undoable
  — the colormap dropdown's nine built-in presets record undo on switch, but the
  inline stop editor writes straight to the gradient without an UndoHistory step.
- `emission_source` (NodePath) is not serialized by CompositionIO because
  NodePaths are scene-relative; the MESH_SURFACE emitter mode requires manual
  reconnection after load.
- Recording writes uncompressed PNGs. For video, pipe the sequence through
  ffmpeg: `ffmpeg -r 24 -i frame_%05d.png -c:v libx264 output.mp4`.
