# Poly-Vis

A real-time visualization tool built in **Godot 4.6** (Forward+) for creating
low-poly meshes, GPU particle flow fields, crumpled-cloth surfaces, and
interactive influence fields. Everything is procedural and driven from a live
parameter panel, so you can sculpt a scene, tweak it in real time, and export
stills or image sequences.

![Godot](https://img.shields.io/badge/Godot-4.6-478CBF?logo=godotengine&logoColor=white)

---

## Features

- **Procedural visualizations**, each fully parameterized in a side panel:
  - **PolyMesh** — displaced low-poly icosphere with solid / wireframe / lattice
    render modes, colormaps, rim light, posterize, and LOD.
  - **PolyParticles** — `GPUParticles3D` curl-noise flow field with multiple
    emitter and particle shapes, color palettes, and an auto-budget mode.
  - **PolyCloth** — sprawling domain-warped cloth sheet that folds, drapes,
    varies its crumple height, bends into 3D forms, and can be punched with holes.
  - **Influence** — movable attract/repel field that dents meshes and cloth and
    steers particles; can follow the mouse or an OptiTrack rigid body.
- **Live parameter panel** — every control is generated from each object's
  schema, with undo/redo, collapsible sections, and a fullscreen clean view.
- **Built-in presets** — load a complete scene from the dropdown (see below).
- **Save / load** compositions to JSON, and duplicate objects.
- **Capture** — screenshots (with optional 2× upscale) and PNG image-sequence
  recording, with an optional HUD logo watermark.
- **OptiTrack / NatNet** motion-capture input (Windows, via the bundled plugin).

---

## Requirements

- [Godot Engine **4.6**](https://godotengine.org/download) (Forward+ renderer).
- No external dependencies — the OptiTrack plugin is bundled under `addons/`.

> The OptiTrack GDExtension ships a **Windows x86_64 debug** DLL only, so live
> motion-capture streaming works when running from the editor on Windows. The
> rest of the app runs on any platform Godot 4.6 supports — OptiTrack features
> simply no-op when the plugin or a Motive connection is unavailable.

---

## Getting started

1. **Clone** the repository:
   ```sh
   git clone https://github.com/<your-org>/Poly-Vis.git
   ```
2. **Open in Godot** — launch Godot 4.6, click *Import*, and select the
   `project.godot` file in the project root.
3. **Run** the project (<kbd>F5</kbd>). `scenes/Main.tscn` is the main scene.
4. Use the panel on the right to add objects, load a preset, and tweak
   parameters. Orbit the camera with the middle mouse button.

To try a complete scene immediately, pick one from the **Presets…** dropdown at
the top of the panel.

---

## Controls

### Camera (mouse)

| Action | Control |
|---|---|
| Orbit (yaw / pitch) | Middle-drag |
| Pan the target | <kbd>Shift</kbd> + middle-drag |
| Zoom | Scroll wheel |
| Drag the selected influence | Left-drag |

### Keyboard shortcuts

| Key | Action |
|---|---|
| <kbd>Tab</kbd> | Cycle object selection |
| <kbd>1</kbd>–<kbd>9</kbd> | Select object by index |
| <kbd>F</kbd> | Focus camera on the selected object |
| <kbd>Space</kbd> | Toggle animation on the selected mesh |
| <kbd>H</kbd> | Hide / show the parameter panel |
| <kbd>F11</kbd> | Fullscreen clean view (hide all options) |
| <kbd>Delete</kbd> / <kbd>Backspace</kbd> | Remove the selected object |
| <kbd>Ctrl</kbd>+<kbd>D</kbd> | Duplicate the selected object |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> | Save composition |
| <kbd>Ctrl</kbd>+<kbd>Z</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Z</kbd> | Undo / redo |

---

## The parameter panel

The right-docked panel drives the whole app, top to bottom:

- **Object selector** + add (`+ Mesh`, `+ Pts`, `+ Cloth`, `+ Inf`) / remove.
- **Presets / Save / Load / Duplicate**.
- **Capture / Record** with a frame-rate selector.
- **Global modules** — camera, scene environment (background + bloom), HUD logo,
  and selection ring.
- **Per-object controls** for the currently selected object.

The **⛶** button (or <kbd>F11</kbd>) collapses the panel to a corner chip and
fullscreens the window for a clean, presentation-ready view.

---

## Presets

Pick any of these from the **Presets…** dropdown:

| Preset | What it shows |
|---|---|
| **Default** | A single displaced PolyMesh |
| **Neon Rain** | Layered particle rain + spark fountain in a dark bloom-lit room |
| **Petal Storm** | Animated, heavily displaced mesh |
| **Draped Silk** | Calm two-tone cloth drape (pink + periwinkle) |
| **Sculpted Drape** | Dramatic crumpled, flowing cloth with holes |
| **Glacier Drape** | Calm cloth drape (teal + amber) |
| **Dune Drape** | Wide low cloth sheet (purple-yellow + blue) |
| **Crystal Lattice** | Metallic wireframe-lattice mesh |
| **Lava Flow** | Glowing posterized mesh + ember particles |
| **Aurora** | Turbulent particle field |
| **Void Sphere** | Dark rim-lit mesh with a repel influence |

---

## Capturing output

- **Capture** / **2×** save a PNG screenshot (UI hidden) to the project's
  `user://` directory.
- **● Rec** writes a numbered PNG sequence to `user://sequence_*/`. Encode it to
  video with ffmpeg, e.g.:
  ```sh
  ffmpeg -r 24 -i frame_%05d.png -c:v libx264 output.mp4
  ```

The HUD logo (configured under the panel's **HUD Logo** section) stays visible in
captures as a watermark.

---

## OptiTrack motion capture

An **Influence** object can be driven by an OptiTrack rigid body streamed from
Motive over NatNet. In the influence's **OptiTrack** panel section:

1. Set the **Server IP** (Motive host) and **Client IP** (this machine), and
   choose **multicast** or unicast.
2. Click **Connect / Reconnect**.
3. Enable **Track Rigid Body** and set the **Rigid Body Asset ID** to a streamed
   asset.
4. Optionally enable **Project to View** to lock the tracked position to the
   current camera view (screen-space with fixed depth).

Connection settings save and load with the composition. The editor's OptiTrack
dock and `addons/optitrack_plugin/optitrack_settings.tres` are an alternative
place to configure the connection.

---

## Project structure

```
scripts/          GDScript source — one class per file
shaders/          GLSL shaders — one per visual system
scenes/           Main.tscn (app), ParticleDemo.tscn (standalone demo)
resources/        Bundled assets (HUD logos, etc.)
addons/           Third-party plugins (optitrack_plugin)
CLAUDE.md         Architecture reference / developer docs
```

For a deep dive into the architecture — class responsibilities, the shader
uniform conventions, the serialization format, and how to add a new
visualization type or parameter — see [CLAUDE.md](CLAUDE.md).
