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
├── HudLogo [CanvasLayer]      Added at runtime — logo overlay (layer 0, in captures)
│
└── UI [CanvasLayer]           layer 1 — hidden during capture
    ├── ParameterPanel         Right-docked control panel (340 px)
    └── FPS label              Top-left corner, added at runtime
```

---

## Core classes

### VisualizationManager
Central object registry. All managed objects (`PolyMesh`, `PolyParticles`,
`InfluenceObject`) are direct children. Emits `objects_changed` and
`selection_changed(obj)`.

Key methods: `add_mesh()`, `add_particles()`, `add_influence()`,
`remove_selected()`, `clear_all()`, `select(obj)`.

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
(`rigid_body_asset_id` + `track_position_offset`) instead of the mouse — see
"OptiTrack motion capture" below.

### InfluenceController
Runs each frame: gathers enabled influences → packs into fixed-size arrays
(max 8) → calls `set_influences()` on every managed object. Per influence,
`_update_follow()` positions it from an OptiTrack rigid body (`track_rigid_body`,
via `_optitrack_pos()`), else from the mouse (`follow_mouse`). A PolyParticles with
`follow_influence` is instead moved to the active influence's position and gets a
0-count (no force). Also handles left-mouse drag on the selected influence and
fires `proximity_entered` / `proximity_exited` signals when influences cross object
boundaries. `burst_on_enter` (restart particles on proximity-enter) defaults OFF —
a follow-mouse influence would otherwise reset particles constantly as it crosses
the bounds.

### GradientColormap
`Resource` wrapping a `Gradient` and baking it to a `GradientTexture1D`.
Presets: VIRIDIS (1), PINK_RED_WHITE (2), PURPLE_YELLOW (3), GREEN_TEAL (4).
Factory: `GradientColormap.create(Preset)`. Emits `changed` when the gradient
changes so dependent shaders refresh.

### AshimaNoise
Static-only CPU port of the Ashima 3D simplex noise (`snoise3`) that the spatial
shaders use. Lets CPU-animated geometry (PolyMesh's `animate_lattice`) match the
GPU-animated surface, which calls the identical `snoise` in the shader.

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

Supported types: `float`, `int`, `bool`, `color`, `enum`, `vector3`,
`colormap_preset`, `action`. Sliders record undo on `drag_ended`; booleans and
enums record immediately. Colors record on `popup_closed`. An `action` prop
renders a button that calls `obj.<name>()` then refreshes the object's controls;
it stores no value and CompositionIO skips it during (de)serialization.

Panel top-to-bottom: title → object selector → add/remove → preset/save/load/dup
→ capture/record → status line → hint bar → camera → scene → HUD logo → selection
ring → object sections. Camera/scene/hud/gizmo are global modules in a static
area; managed-object controls render in `_object_host` below them.

### HudLogo
`CanvasLayer` overlay showing a logo over the front of the view. Bundles the
OptiTrack white/black PNGs (`resources/logos/`) as presets via the `logo` enum,
plus a `custom_path` for any imported image (`import_logo()` action opens a file
dialog; external paths load through `Image.load_from_file`). Controls `corner`,
`size_scale`, `opacity`, `margin`. Sits at `layer = 0` (below the panel's
CanvasLayer, above the 3D view) and is NOT the CaptureManager's `ui_layer`, so it
stays visible in screenshots/recordings as a watermark. Schema-driven like
SceneEnvironment; serialized under `"hud"`. `custom_path` is a `"string"` schema
prop — serialized but rendered with no panel control (set via the Import button).

Drop shadow (`shadow_enabled`, `shadow_color`, `shadow_offset_x/y`): a second
TextureRect (`_shadow`) added before the logo rect so it renders behind. Uses the
same texture/size/stretch via `hud_shadow.gdshader`, which fills the logo's alpha
silhouette with `shadow_color` (the shadow is the logo's SHAPE in that color, not
a tint of its pixels), offset by `shadow_offset_*`. `shadow_color.a` controls
shadow strength; `opacity` fades both rects.

NOTE: the enum is `LogoCorner`, not `Corner` — `Corner` is a Godot built-in enum
and shadowing it is a parse error.

### CompositionIO
Stateless serializer. `serialize(manager, camera, scene=null, hud=null,
gizmo=null)` → Dictionary; `apply(data, manager, camera, scene=null, hud=null,
gizmo=null)` → rebuilds from Dictionary. File I/O: `save_json` / `load_json`.
Encoding: colors → `[r,g,b,a]`, Vector3 → `[x,y,z]`, enums → int, strings →
as-is, colormaps → `{"preset": N, "offsets": [], "colors": []}`. Camera, `scene`
(SceneEnvironment), `hud` (HudLogo), and `gizmo` (SelectionGizmo) are each
serialized by walking their `get_param_schema()` via the shared `_schema_to_dict`
/ `_dict_to_schema` helpers. On load, if a module is supplied but the composition
lacks its block, `reset_defaults()` runs first (white room / no logo / ring off).

### SceneEnvironment
`RefCounted` wrapper around the `WorldEnvironment.environment` resource, bound by
Main at startup via `bind()`. Exposes `bg_color`, `bloom_enabled`,
`bloom_intensity` through `get_param_schema()` so they render in the panel
(under the camera) and serialize under the `"scene"` key. `bg_color` also drives
`ambient_light_color` (dark background → dark room). Bloom uses additive glow
with a 0.7 HDR threshold, so particles with `particle_brightness > 1` bloom.

### UndoHistory
Thin wrapper around Godot's built-in `UndoRedo`. `record_property(obj, prop,
old_val, new_val)` commits an action with `execute=false` (value already applied).
`history_changed` signal fires after every undo/redo; Main connects it to
`panel.show_object(selected)` to refresh controls.

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

### InputManager
`_unhandled_key_input` handler. Delegates to VisualizationManager, panel, camera,
and UndoHistory. Full shortcut list in the script header comment.

### BuiltInPresets
Const dictionary of CompositionIO-compatible scenes (Default, Neon Rain, Petal
Storm, Draped Silk, Sculpted Drape, Glacier Drape, Dune Drape, Crystal Lattice,
Lava Flow, Aurora, Void Sphere). Applied by the preset dropdown in the panel.
Neon Rain is the only one that ships a `"scene"` block (dark room + bloom) and
stacks three PolyParticles layers — palette-colored disc rain, a
`follow_influence` spark fountain trailing the cursor, and downward Streak rain —
plus a hidden follow-mouse influence. Draped Silk, Sculpted Drape, Glacier Drape,
and Dune Drape are the PolyCloth showcases, each pairing a warm colormap with a
contrasting `cool_color` for the two-tone facet split (Draped/Sculpted: pink +
periwinkle, Glacier: teal + amber, Dune: purple-yellow + blue). Draped Silk,
Glacier, and Dune are the calm variants — broad folds, low `fold`/`warp`, moderate
`curvature_amount`. Sculpted Drape is the dramatic one: high `amplitude`/`warp`/
`curvature_amount` and fine `resolution` give the heavily-crumpled, ribbon-like
flowing form whose folds arc apart to reveal the white room through the gaps
between them.

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

### particle_flow.gdshader (particles)
Similar set — all pushed via `_mat.set_shader_parameter()`. Curl-noise flow
field is divergence-free; `u_turbulence` scales the curl acceleration.
Influence fields attract (+) or accelerate particles away (−). Color priority in
`process()`: `u_palette[6]` (when `u_palette_count > 0`, flat per-particle pick via
the seed `CUSTOM.x`) → colormap → `u_color_a`/`u_color_b` lerp; then influence
tint, then `u_particle_brightness`.

### polycloth.gdshader (spatial)
PolyCloth's surface shader. Shares the colormap / posterize / contrast /
brightness / rim / influence uniform conventions with `polymesh_deform`, but:
animated displacement and influence dents ride along world-up (Y) instead of a
radial direction (coherent on a plane); color decisions use the baked
object-space normal varying `v_face_n` (camera-stable), while lighting uses the
derivative normal. Adds `u_cool_color`/`u_cool_strength`/`u_cool_dir` for the
warm/cool facet split, and reads baked height-noise + fold magnitude from `UV2`.

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
      "params": {
        "subdivisions": 3,
        "colormap": { "preset": 1, "offsets": [], "colors": [] },
        "base_color": [0.85, 0.2, 0.45, 1.0]
      }
    }
  ],
  "scene": { "bg_color": [0.02, 0.02, 0.05, 1.0], "bloom_enabled": true, "bloom_intensity": 1.2 },
  "hud": { "enabled": true, "logo": 1, "corner": 2, "size_scale": 0.16, "opacity": 1.0, "shadow_enabled": true, "shadow_color": [0.0, 0.0, 0.0, 0.5], "shadow_offset_x": 8.0, "shadow_offset_y": 8.0 },
  "camera": { "target": [0.0, 0.0, 0.0], "distance": 6.0 }
}
```

The `"scene"` and `"hud"` blocks are optional; when absent on load the
environment resets to the default white room (no bloom) and the logo turns off.
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

Autoload API used by Poly-Vis (all defensive — see `_optitrack_pos`):
`is_connected_to_motive() -> bool`, `get_rigid_body_pos(asset_id) -> Vector3`
(already in Godot space), `get_rigid_body_rot(asset_id) -> Quaternion`.

Integration: an `InfluenceObject` with `track_rigid_body = true` has its world
position driven by `OptiTrack.get_rigid_body_pos(rigid_body_asset_id) +
track_position_offset`, evaluated each frame in `InfluenceController._update_follow`
(priority over `follow_mouse`). The lookup is guarded with
`get_node_or_null("/root/OptiTrack")` + `has_method` + connection checks, so the
app runs normally with the plugin absent, on non-Windows, or with Motive offline
— the influence just holds position. Connection settings (server/client IP,
multicast) live in `optitrack_settings.tres` and the editor's OptiTrack dock.
To use: open in the editor, configure + start the connection in the OptiTrack
dock, set the influence's `rigid_body_asset_id` to a streamed asset, run.

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

---

## Known limitations / future work

- Undo/redo covers parameter sliders, booleans, enums, and colors. Add/remove
  object operations are not yet undoable.
- LOD rebuilds the lattice MultiMesh on level change; that rebuild is
  synchronous and may cause a single-frame hitch at transition distance.
- Colormap preset picker in the panel does not reflect custom gradients edited
  via the inspector — only the four built-in presets are selectable.
- `emission_source` (NodePath) is not serialized by CompositionIO because
  NodePaths are scene-relative; the MESH_SURFACE emitter mode requires manual
  reconnection after load.
- Recording writes uncompressed PNGs. For video, pipe the sequence through
  ffmpeg: `ffmpeg -r 24 -i frame_%05d.png -c:v libx264 output.mp4`.
