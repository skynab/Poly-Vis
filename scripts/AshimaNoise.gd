class_name AshimaNoise
## CPU port of the Ashima 3D simplex noise (`snoise`) used by the spatial shaders.
##
## Geometry animated on the CPU (PolyMesh's wireframe lattice) must use the same
## noise as the GPU-animated surface so the two track each other — especially in
## SOLID_WIREFRAME mode. `polymesh_deform.gdshader` uses this exact function, so
## this port keeps them in lock-step (modulo GPU/CPU float precision).

static func _mod289_3(x: Vector3) -> Vector3:
	return x - (x * (1.0 / 289.0)).floor() * 289.0

static func _mod289_4(x: Vector4) -> Vector4:
	return x - (x * (1.0 / 289.0)).floor() * 289.0

static func _permute(x: Vector4) -> Vector4:
	return _mod289_4(((x * 34.0) + Vector4.ONE) * x)

static func _taylor_inv_sqrt(r: Vector4) -> Vector4:
	return Vector4.ONE * 1.79284291400159 - r * 0.85373472095314

static func _step3(edge: Vector3, x: Vector3) -> Vector3:
	return Vector3(
		1.0 if x.x >= edge.x else 0.0,
		1.0 if x.y >= edge.y else 0.0,
		1.0 if x.z >= edge.z else 0.0)

## 3D simplex noise, range ~[-1, 1]. Mirrors snoise() in the spatial shaders.
static func snoise3(v: Vector3) -> float:
	var cx := 1.0 / 6.0
	var cy := 1.0 / 3.0
	var i := (v + Vector3.ONE * ((v.x + v.y + v.z) * cy)).floor()       # floor(v + dot(v,C.yyy))
	var x0 := v - i + Vector3.ONE * ((i.x + i.y + i.z) * cx)            # v - i + dot(i,C.xxx)
	var g := _step3(Vector3(x0.y, x0.z, x0.x), x0)
	var l := Vector3.ONE - g
	var i1 := g.min(Vector3(l.z, l.x, l.y))
	var i2 := g.max(Vector3(l.z, l.x, l.y))
	var x1 := x0 - i1 + Vector3.ONE * cx
	var x2 := x0 - i2 + Vector3.ONE * cy
	var x3 := x0 - Vector3.ONE * 0.5
	i = _mod289_3(i)
	var p := _permute(_permute(_permute(
			Vector4(i.z, i.z, i.z, i.z) + Vector4(0.0, i1.z, i2.z, 1.0))
			+ Vector4(i.y, i.y, i.y, i.y) + Vector4(0.0, i1.y, i2.y, 1.0))
			+ Vector4(i.x, i.x, i.x, i.x) + Vector4(0.0, i1.x, i2.x, 1.0))
	var n_ := 0.142857142857
	var ns := Vector3(2.0, 0.5, 1.0) * n_ - Vector3(0.0, 1.0, 0.0)       # n_ * D.wyz - D.xzx
	var j := p - (p * (ns.z * ns.z)).floor() * 49.0
	var x_ := (j * ns.z).floor()
	var y_ := (j - x_ * 7.0).floor()
	var px := x_ * ns.x + Vector4.ONE * ns.y
	var py := y_ * ns.x + Vector4.ONE * ns.y
	var h := Vector4.ONE - px.abs() - py.abs()
	var b0 := Vector4(px.x, px.y, py.x, py.y)
	var b1 := Vector4(px.z, px.w, py.z, py.w)
	var s0 := b0.floor() * 2.0 + Vector4.ONE
	var s1 := b1.floor() * 2.0 + Vector4.ONE
	var sh := Vector4(                                                   # -step(h, 0)
		-1.0 if h.x <= 0.0 else 0.0,
		-1.0 if h.y <= 0.0 else 0.0,
		-1.0 if h.z <= 0.0 else 0.0,
		-1.0 if h.w <= 0.0 else 0.0)
	var a0 := Vector4(b0.x, b0.z, b0.y, b0.w) + Vector4(s0.x, s0.z, s0.y, s0.w) * Vector4(sh.x, sh.x, sh.y, sh.y)
	var a1 := Vector4(b1.x, b1.z, b1.y, b1.w) + Vector4(s1.x, s1.z, s1.y, s1.w) * Vector4(sh.z, sh.z, sh.w, sh.w)
	var p0 := Vector3(a0.x, a0.y, h.x)
	var p1 := Vector3(a0.z, a0.w, h.y)
	var p2 := Vector3(a1.x, a1.y, h.z)
	var p3 := Vector3(a1.z, a1.w, h.w)
	var norm := _taylor_inv_sqrt(Vector4(p0.dot(p0), p1.dot(p1), p2.dot(p2), p3.dot(p3)))
	p0 *= norm.x
	p1 *= norm.y
	p2 *= norm.z
	p3 *= norm.w
	var m := Vector4(
		max(0.6 - x0.dot(x0), 0.0),
		max(0.6 - x1.dot(x1), 0.0),
		max(0.6 - x2.dot(x2), 0.0),
		max(0.6 - x3.dot(x3), 0.0))
	m = m * m
	var grads := Vector4(p0.dot(x0), p1.dot(x1), p2.dot(x2), p3.dot(x3))
	return 42.0 * (m * m).dot(grads)
