## Built-in composition presets shipped with Poly-Vis (Prompt 6.1).
##
## Each entry is a CompositionIO-compatible Dictionary.  Load via:
##   CompositionIO.apply(BuiltInPresets.PRESETS["Crystal Lattice"], manager, camera)
##
## Colormap encoding: {"preset": N, "offsets": [], "colors": []}
##   N matches GradientColormap.Preset: CUSTOM=0 VIRIDIS=1 PINK_RED_WHITE=2
##                                       PURPLE_YELLOW=3 GREEN_TEAL=4
class_name BuiltInPresets

const PRESETS: Dictionary = {
	"Crystal Lattice": {
		"version": 1,
		"objects": [
			{
				"type": "PolyMesh",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"subdivisions": 3,
					"radius": 1.5,
					"noise_amplitude": 0.28,
					"noise_frequency": 1.4,
					"seed": 42,
					"render_mode": 2,
					"base_color": [0.2, 0.5, 0.9, 1.0],
					"surface_roughness": 0.12,
					"surface_metallic": 0.9,
					"colormap": {"preset": 1, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": 0.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 8,
					"rim_strength": 1.6,
					"rim_power": 4.5,
					"rim_color": [0.4, 0.85, 1.0, 1.0],
					"translucency": 0.12,
					"edge_radius": 0.012,
					"node_radius": 0.026,
					"edge_color": [0.7, 0.88, 1.0, 1.0],
					"node_color": [0.9, 0.97, 1.0, 1.0],
					"node_glow": 2.0,
					"lattice_opacity": 0.85,
					"edge_facets": 4,
					"animate": true,
					"anim_amplitude": 0.14,
					"anim_frequency": 1.5,
					"anim_speed": 0.55
				}
			}
		],
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 5.0
		}
	},

	"Lava Flow": {
		"version": 1,
		"objects": [
			{
				"type": "PolyMesh",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"subdivisions": 3,
					"radius": 1.5,
					"noise_amplitude": 0.5,
					"noise_frequency": 0.8,
					"seed": 7,
					"render_mode": 0,
					"base_color": [0.9, 0.15, 0.02, 1.0],
					"surface_roughness": 0.75,
					"surface_metallic": 0.0,
					"colormap": {"preset": 2, "offsets": [], "colors": []},
					"color_source": 3,
					"color_min": 0.0,
					"color_max": 1.0,
					"posterize": true,
					"posterize_steps": 6,
					"rim_strength": 0.9,
					"rim_power": 2.0,
					"rim_color": [1.0, 0.35, 0.0, 1.0],
					"translucency": 0.35,
					"edge_radius": 0.008,
					"node_radius": 0.018,
					"edge_color": [1.0, 0.55, 0.0, 1.0],
					"node_color": [1.0, 0.85, 0.2, 1.0],
					"node_glow": 1.8,
					"lattice_opacity": 1.0,
					"edge_facets": 4,
					"animate": true,
					"anim_amplitude": 0.42,
					"anim_frequency": 0.75,
					"anim_speed": 1.3
				}
			},
			{
				"type": "PolyParticles",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"count": 2000,
					"particle_lifetime": 4.0,
					"emitter_shape": 1,
					"emitter_extents": [1.8, 1.8, 1.8],
					"direction": [0.0, 1.0, 0.0],
					"initial_speed": 1.2,
					"spread": 0.75,
					"gravity": [0.0, -0.25, 0.0],
					"flow_scale": 1.1,
					"flow_speed": 1.4,
					"turbulence": 2.5,
					"drag": 1.2,
					"flow_seed": 3,
					"colormap": {"preset": 2, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": 0.0,
					"color_max": 1.0,
					"color_a": [1.0, 0.35, 0.0, 1.0],
					"color_b": [1.0, 0.95, 0.7, 1.0]
				}
			}
		],
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 6.0
		}
	},

	"Aurora": {
		"version": 1,
		"objects": [
			{
				"type": "PolyParticles",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"count": 8000,
					"particle_lifetime": 9.0,
					"emitter_shape": 1,
					"emitter_extents": [3.5, 3.5, 3.5],
					"direction": [0.0, 1.0, 0.0],
					"initial_speed": 0.4,
					"spread": 1.0,
					"gravity": [0.0, 0.0, 0.0],
					"flow_scale": 0.55,
					"flow_speed": 0.35,
					"turbulence": 7.0,
					"drag": 0.45,
					"flow_seed": 123,
					"colormap": {"preset": 4, "offsets": [], "colors": []},
					"color_source": 0,
					"color_min": -2.5,
					"color_max": 2.5,
					"color_a": [0.0, 0.85, 0.45, 1.0],
					"color_b": [0.75, 1.0, 0.35, 1.0]
				}
			}
		],
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 9.0
		}
	},

	"Void Sphere": {
		"version": 1,
		"objects": [
			{
				"type": "PolyMesh",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"subdivisions": 4,
					"radius": 1.8,
					"noise_amplitude": 0.22,
					"noise_frequency": 2.1,
					"seed": 99,
					"render_mode": 0,
					"base_color": [0.04, 0.0, 0.09, 1.0],
					"surface_roughness": 0.28,
					"surface_metallic": 0.5,
					"colormap": {"preset": 3, "offsets": [], "colors": []},
					"color_source": 1,
					"color_min": 0.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 8,
					"rim_strength": 2.0,
					"rim_power": 5.5,
					"rim_color": [0.65, 0.0, 1.0, 1.0],
					"translucency": 0.0,
					"edge_radius": 0.008,
					"node_radius": 0.018,
					"edge_color": [0.45, 0.0, 0.75, 1.0],
					"node_color": [0.75, 0.1, 1.0, 1.0],
					"node_glow": 2.5,
					"lattice_opacity": 1.0,
					"edge_facets": 4,
					"animate": true,
					"anim_amplitude": 0.07,
					"anim_frequency": 2.6,
					"anim_speed": 0.28
				}
			},
			{
				"type": "Influence",
				"position": [0.0, 0.0, 2.5],
				"params": {
					"enabled": true,
					"mode": 1,
					"radius": 2.6,
					"strength": 4.0,
					"influence_color": [0.7, 0.0, 1.0, 1.0],
					"follow_mouse": true
				}
			}
		],
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 6.5
		}
	}
}
