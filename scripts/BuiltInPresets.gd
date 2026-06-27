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
	"Default": {
		"version": 1,
		"objects": [
			{
				"type": "PolyMesh",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"subdivisions": 3,
					"radius": 1.5,
					"noise_amplitude": 0.35,
					"noise_frequency": 0.8,
					"noise_seed": 0,
					"render_mode": 0,
					"base_color": [0.85, 0.2, 0.45, 1.0],
					"surface_roughness": 0.7,
					"surface_metallic": 0.0,
					"color_source": 0,
					"color_min": -1.8,
					"color_max": 1.8,
					"posterize": false,
					"posterize_steps": 5,
					"contrast": 1.0,
					"brightness": 1.0,
					"rim_strength": 0.0,
					"rim_power": 2.5,
					"rim_color": [1.0, 1.0, 1.0, 1.0],
					"translucency": 0.0,
					"edge_radius": 0.012,
					"node_radius": 0.03,
					"edge_color": [0.75, 0.76, 0.8, 1.0],
					"node_color": [0.92, 0.96, 1.0, 1.0],
					"node_glow": 0.8,
					"lattice_opacity": 1.0,
					"edge_facets": 4,
					"animate": false,
					"anim_amplitude": 0.25,
					"anim_frequency": 1.2,
					"anim_speed": 0.6
				}
			}
		],
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 6.0
		}
	},

	"Neon Rain": {
		"version": 1,
		"objects": [
			{
				"type": "PolyParticles",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"count": 5000,
					"particle_lifetime": 11.0,
					"emitter_shape": 2,
					"emitter_extents": [6.0, 6.0, 6.0],
					"emitter_size": 1.9,
					"particle_shape": 3,
					"particle_size": 0.09,
					"particle_size_curve": false,
					"particle_rotation_speed": 0.6,
					"direction": [0.0, -1.0, 0.0],
					"initial_speed": 0.3,
					"spread": 0.6,
					"gravity": [0.0, -0.12, 0.0],
					"flow_scale": 0.5,
					"flow_speed": 0.25,
					"turbulence": 1.5,
					"drag": 0.6,
					"flow_seed": 11,
					"palette_enable_1": true, "palette_color_1": [1.0, 0.2, 0.5, 1.0],
					"palette_enable_2": true, "palette_color_2": [1.0, 0.75, 0.2, 1.0],
					"palette_enable_3": true, "palette_color_3": [0.3, 1.0, 0.6, 1.0],
					"palette_enable_4": true, "palette_color_4": [0.2, 0.7, 1.0, 1.0],
					"palette_enable_5": true, "palette_color_5": [0.8, 0.3, 1.0, 1.0],
					"particle_brightness": 2.0
				}
			},
			{
				"type": "PolyParticles",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"count": 1400,
					"particle_lifetime": 3.0,
					"emitter_shape": 1,
					"emitter_extents": [0.3, 0.3, 0.3],
					"emitter_size": 1.0,
					"particle_shape": 4,
					"particle_size": 0.06,
					"particle_size_curve": true,
					"particle_rotation_speed": 2.0,
					"direction": [0.0, 1.0, 0.0],
					"initial_speed": 4.0,
					"spread": 0.35,
					"gravity": [0.0, -1.5, 0.0],
					"flow_scale": 0.8,
					"flow_speed": 0.5,
					"turbulence": 2.0,
					"drag": 0.3,
					"flow_seed": 5,
					"follow_influence": true,
					"palette_enable_1": true, "palette_color_1": [1.0, 0.95, 0.6, 1.0],
					"palette_enable_2": true, "palette_color_2": [1.0, 0.5, 0.9, 1.0],
					"palette_enable_3": true, "palette_color_3": [0.6, 0.85, 1.0, 1.0],
					"particle_brightness": 2.2
				}
			},
			{
				"type": "PolyParticles",
				"position": [0.0, 5.0, 0.0],
				"params": {
					"count": 2000,
					"particle_lifetime": 5.0,
					"emitter_shape": 2,
					"emitter_extents": [7.0, 0.5, 7.0],
					"emitter_size": 1.0,
					"particle_shape": 5,
					"particle_size": 0.13,
					"particle_size_curve": false,
					"particle_rotation_speed": 0.0,
					"direction": [0.0, -1.0, 0.0],
					"initial_speed": 2.0,
					"spread": 0.04,
					"gravity": [0.0, -3.0, 0.0],
					"flow_scale": 0.3,
					"flow_speed": 0.2,
					"turbulence": 0.4,
					"drag": 0.1,
					"flow_seed": 21,
					"palette_enable_1": true, "palette_color_1": [1.0, 0.3, 0.5, 1.0],
					"palette_enable_2": true, "palette_color_2": [0.3, 1.0, 0.7, 1.0],
					"palette_enable_3": true, "palette_color_3": [0.3, 0.6, 1.0, 1.0],
					"palette_enable_4": true, "palette_color_4": [1.0, 0.9, 0.4, 1.0],
					"particle_brightness": 2.0
				}
			},
			{
				"type": "Influence",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"enabled": true,
					"mode": 0,
					"radius": 3.0,
					"strength": 3.0,
					"influence_color": [0.2, 0.9, 1.0, 1.0],
					"show_visual": false,
					"follow_mouse": true
				}
			}
		],
		"scene": {
			"bg_color": [0.02, 0.02, 0.05, 1.0],
			"bloom_enabled": true,
			"bloom_intensity": 0.6
		},
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 8.0
		}
	},

	"Petal Storm": {
		"version": 1,
		"objects": [
			{
				"type": "PolyMesh",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"subdivisions": 4,
					"radius": 2.2,
					"noise_amplitude": 1.5,
					"noise_frequency": 0.32,
					"noise_seed": 17,
					"render_mode": 0,
					"base_color": [0.85, 0.2, 0.45, 1.0],
					"surface_roughness": 0.85,
					"surface_metallic": 0.0,
					"colormap": {"preset": 2, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": -1.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 5,
					"contrast": 1.2,
					"brightness": 1.1,
					"rim_strength": 0.0,
					"rim_power": 2.5,
					"rim_color": [1.0, 1.0, 1.0, 1.0],
					"translucency": 0.0,
					"edge_radius": 0.012,
					"node_radius": 0.03,
					"edge_color": [0.75, 0.76, 0.8, 1.0],
					"node_color": [0.92, 0.96, 1.0, 1.0],
					"node_glow": 0.8,
					"lattice_opacity": 1.0,
					"edge_facets": 4,
					"animate": true,
					"anim_amplitude": 0.55,
					"anim_frequency": 0.48,
					"anim_speed": 0.28
				}
			}
		],
		"camera": {
			"target": [0.0, 0.0, 0.0],
			"distance": 3.2
		}
	},

	"Draped Silk": {
		"version": 1,
		"objects": [
			{
				"type": "PolyCloth",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"extent": 7.0,
					"resolution": 110,
					"amplitude": 2.3,
					"amplitude_variance": 0.5,
					"amplitude_variance_scale": 0.08,
					"frequency": 0.13,
					"warp": 1.1,
					"fold": 0.35,
					"noise_seed": 3,
					"curvature_amount": 2.4,
					"curvature_complexity": 4,
					"shape_seed": 41,
					"surface_roughness": 0.85,
					"surface_metallic": 0.0,
					"colormap": {"preset": 2, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": -1.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 5,
					"contrast": 1.1,
					"brightness": 1.05,
					"cool_color": [0.6, 0.65, 0.98, 1.0],
					"cool_strength": 0.85,
					"cool_dir": [0.2, 1.0, 0.15],
					"rim_strength": 0.25,
					"rim_power": 2.5,
					"rim_color": [1.0, 1.0, 1.0, 1.0],
					"translucency": 0.0,
					"animate": true,
					"anim_amplitude": 0.1,
					"anim_frequency": 0.5,
					"anim_speed": 0.3
				}
			}
		],
		"camera": {
			"target": [0.0, 0.3, 0.0],
			"distance": 7.0
		}
	},

	"Sculpted Drape": {
		"version": 1,
		"objects": [
			{
				"type": "PolyCloth",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"extent": 7.5,
					"resolution": 150,
					"amplitude": 4.0,
					"amplitude_variance": 0.92,
					"amplitude_variance_scale": 0.055,
					"frequency": 0.14,
					"warp": 1.9,
					"fold": 0.6,
					"noise_seed": 21,
					"curvature_amount": 5.0,
					"curvature_complexity": 7,
					"shape_seed": 137,
					"hole_amount": 0.4,
					"hole_scale": 0.22,
					"surface_roughness": 0.82,
					"surface_metallic": 0.0,
					"colormap": {"preset": 2, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": -1.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 5,
					"contrast": 1.25,
					"brightness": 1.05,
					"cool_color": [0.6, 0.62, 0.98, 1.0],
					"cool_strength": 0.8,
					"cool_dir": [0.25, 1.0, 0.2],
					"rim_strength": 0.3,
					"rim_power": 2.5,
					"rim_color": [1.0, 1.0, 1.0, 1.0],
					"translucency": 0.0,
					"animate": true,
					"anim_amplitude": 0.1,
					"anim_frequency": 0.5,
					"anim_speed": 0.3
				}
			}
		],
		"camera": {
			"target": [0.0, 0.3, 0.0],
			"distance": 6.5
		}
	},

	"Glacier Drape": {
		"version": 1,
		"objects": [
			{
				"type": "PolyCloth",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"extent": 7.0,
					"resolution": 110,
					"amplitude": 2.5,
					"amplitude_variance": 0.6,
					"amplitude_variance_scale": 0.08,
					"frequency": 0.14,
					"warp": 1.3,
					"fold": 0.4,
					"noise_seed": 64,
					"curvature_amount": 3.0,
					"curvature_complexity": 5,
					"shape_seed": 308,
					"surface_roughness": 0.8,
					"surface_metallic": 0.0,
					"colormap": {"preset": 4, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": -1.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 5,
					"contrast": 1.1,
					"brightness": 1.05,
					"cool_color": [1.0, 0.72, 0.42, 1.0],
					"cool_strength": 0.7,
					"cool_dir": [0.2, 1.0, 0.25],
					"rim_strength": 0.3,
					"rim_power": 2.5,
					"rim_color": [1.0, 1.0, 1.0, 1.0],
					"translucency": 0.0,
					"animate": true,
					"anim_amplitude": 0.1,
					"anim_frequency": 0.5,
					"anim_speed": 0.3
				}
			}
		],
		"camera": {
			"target": [0.0, 0.2, 0.0],
			"distance": 7.5
		}
	},

	"Dune Drape": {
		"version": 1,
		"objects": [
			{
				"type": "PolyCloth",
				"position": [0.0, 0.0, 0.0],
				"params": {
					"extent": 8.0,
					"resolution": 120,
					"amplitude": 2.8,
					"amplitude_variance": 0.65,
					"amplitude_variance_scale": 0.06,
					"frequency": 0.11,
					"warp": 1.2,
					"fold": 0.4,
					"noise_seed": 88,
					"curvature_amount": 2.2,
					"curvature_complexity": 4,
					"shape_seed": 512,
					"surface_roughness": 0.85,
					"surface_metallic": 0.0,
					"colormap": {"preset": 3, "offsets": [], "colors": []},
					"color_source": 2,
					"color_min": -1.0,
					"color_max": 1.0,
					"posterize": false,
					"posterize_steps": 5,
					"contrast": 1.15,
					"brightness": 1.05,
					"cool_color": [0.45, 0.55, 1.0, 1.0],
					"cool_strength": 0.8,
					"cool_dir": [0.15, 1.0, 0.3],
					"rim_strength": 0.3,
					"rim_power": 2.5,
					"rim_color": [1.0, 1.0, 1.0, 1.0],
					"translucency": 0.0,
					"animate": true,
					"anim_amplitude": 0.1,
					"anim_frequency": 0.5,
					"anim_speed": 0.3
				}
			}
		],
		"camera": {
			"target": [0.0, 0.2, 0.0],
			"distance": 8.5
		}
	},

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
					"noise_seed": 42,
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
					"animate_lattice": true,
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
					"noise_seed": 7,
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
					"noise_seed": 99,
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
