# Poly-Vis — Architecture Reference

Godot 4.6 (Forward Plus) runtime visualization tool for low-poly meshes,
GPU particle flow fields, and interactive influence fields.

---

## Directory layout

```
scripts/          GDScript source — one class per file, named to match the class
shaders/          GLSL shaders — one per visual system
scenes/           Main.tscn (editor), ParticleDemo.tscn (standalone demo)
resources/        Empty at runtime; assets go here
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
│
└── UI [CanvasLayer]
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

LOD system (`lod_enabled`, `lod_dist1`, `lod_dist2`): `_update_lod()` runs
each frame when enabled, reduces subdivision level by 1 or 2 beyond the
configured distances, rebuilds only when the level changes.

### PolyParticles
`GPUParticles3D` with a custom `shader_type particles` process material
(`particle_flow.gdshader`). Emitter shapes: Point, Sphere, Box, Mesh Surface.
Mesh-surface emission bakes target vertices into a `FORMAT_RGBF` `ImageTexture`.

Auto-budget (`auto_budget`, `budget_target_fps`): `_process` samples FPS once
per second and scales `amount` proportionally to keep near the target FPS.

### PolyCloth
`MeshInstance3D` rendering a sprawling crumpled-cloth surface — a heavily
domain-warped subdivided plane (vs PolyMesh's centered icosphere). `_build_surface()`
bakes a `(resolution+1)²` grid: domain-warped FBM height along Y (`amplitude`,
`frequency`, `warp`) plus lateral XZ `fold` offsets, emitting unique verts per
triangle for flat normals. Per-vertex height-noise + fold magnitude are packed
into UV2 for the shader's FOLD/NOISE color sources. Uses `polycloth.gdshader`;
no wireframe/lattice. Setters mirror PolyMesh (`rebuild` for geometry,
`_apply_color_and_polish` / `_update_anim_uniforms` otherwise). Implements
`set_influences()` — folds dent under influence spheres like the mesh.

### OrbitCamera
Middle-drag orbits (yaw/pitch), Shift+middle-drag pans the target point,
scroll wheel zooms. Exposes `get_param_schema()` so the panel shows camera
controls alongside object controls.

### InfluenceObject
Movable sphere with translucent shell + solid core. Two modes: ATTRACT
(positive signed_strength) or REPEL (negative). When `follow_mouse = true`
the InfluenceController projects the mouse onto a plane through the influence's
world position.

### InfluenceController
Runs each frame: gathers enabled influences → packs into fixed-size arrays
(max 8) → calls `set_influences()` on every managed object. Also handles
left-mouse drag on the selected influence and fires `proximity_entered` /
`proximity_exited` signals when influences cross object boundaries.

### GradientColormap
`Resource` wrapping a `Gradient` and baking it to a `GradientTexture1D`.
Presets: VIRIDIS (1), PINK_RED_WHITE (2), PURPLE_YELLOW (3), GREEN_TEAL (4).
Factory: `GradientColormap.create(Preset)`. Emits `changed` when the gradient
changes so dependent shaders refresh.

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
  ]}
]
```

Supported types: `float`, `int`, `bool`, `color`, `enum`, `vector3`,
`colormap_preset`. Sliders record undo on `drag_ended`; booleans and enums
record immediately. Colors record on `popup_closed`.

Panel top-to-bottom: title → object selector → add/remove → preset/save/load/dup
→ capture/record → status line → hint bar → camera section → object sections.

### CompositionIO
Stateless serializer. `serialize(manager, camera, scene=null)` → Dictionary;
`apply(data, manager, camera, scene=null)` → rebuilds scene from Dictionary.
File I/O: `save_json` / `load_json`. Encoding: colors → `[r,g,b,a]`, Vector3 →
`[x,y,z]`, enums → int, colormaps → `{"preset": N, "offsets": [], "colors": []}`.
Camera and `scene` (SceneEnvironment) are each serialized by walking their
`get_param_schema()` via the shared `_schema_to_dict` / `_dict_to_schema`
helpers. On load, if `scene` is supplied but the composition has no `"scene"`
block, `scene.reset_defaults()` restores the white room first.

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
Skips `InfluenceObject` (which already draws its own radius sphere).

### InputManager
`_unhandled_key_input` handler. Delegates to VisualizationManager, panel, camera,
and UndoHistory. Full shortcut list in the script header comment.

### BuiltInPresets
Const dictionary of CompositionIO-compatible scenes (Default, Neon Rain, Petal
Storm, Crumpled Silk, Crystal Lattice, Lava Flow, Aurora, Void Sphere). Applied
by the preset dropdown in the panel. Neon Rain is the only one that ships a
`"scene"` block (dark room + bloom) and stacks two PolyParticles layers plus a
follow-mouse influence. Crumpled Silk is the PolyCloth showcase.

---

## Shader conventions

### polymesh_deform.gdshader (spatial)
Uniforms set by PolyMesh setters each frame / on property change:

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
Influence fields attract (+) or accelerate particles away (−).

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
  "camera": { "target": [0.0, 0.0, 0.0], "distance": 6.0 }
}
```

The `"scene"` block is optional; when absent on load the environment resets to
the default white room (no bloom). Only parameters present in `get_param_schema()`
are serialized. Missing keys
on load keep the object's GDScript defaults. Colormap `preset` values map to
`GradientColormap.Preset` enum (CUSTOM=0, VIRIDIS=1, PINK_RED_WHITE=2,
PURPLE_YELLOW=3, GREEN_TEAL=4). Empty `offsets`/`colors` arrays means "use the
preset's built-in gradient."

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
