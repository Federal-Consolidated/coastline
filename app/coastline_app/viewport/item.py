"""The 3D view: a Qt Quick item drawn with QRhi (Metal on macOS, Direct3D on Windows, Vulkan or
OpenGL on Linux). Port of the Metal renderer in Viewport/Sources/Viewport.

Threads: `Viewport` (the item) lives on the UI thread and owns the camera and input. `_Renderer`
runs on Qt Quick's render thread (the UI thread with QSG_RENDER_LOOP=basic). `synchronize`
copies what changed while the UI thread waits; `render` records the GPU commands.

Drawing order (as the Metal app): opaque meshes (writing depth, and a stencil mark where the
stock is nearest), translucent meshes (no depth writes), meshes drawn on top, x-ray lines
(faint, only where the stock is in front), then lines.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PySide6.QtCore import Property, QObject, QPointF, QSize, Qt, QTimer, Signal, Slot
from PySide6.QtGui import (QColor, QRhiBuffer, QRhiCommandBuffer, QRhiDepthStencilClearValue,
                           QRhiGraphicsPipeline, QRhiShaderResourceBinding, QRhiShaderStage,
                           QRhiVertexInputAttribute, QRhiVertexInputBinding, QRhiVertexInputLayout,
                           QRhiViewport, QShader)
from PySide6.QtQml import QmlElement
from PySide6.QtQuick import QQuickRhiItem, QQuickRhiItemRenderer

from .camera import OrbitCamera
from .scene import SEGMENT_DTYPE, Scene

QML_IMPORT_NAME = "Coastline.Viewport"
QML_IMPORT_MAJOR_VERSION = 1

SHADERS = Path(__file__).resolve().parent / "shaders"
BACKGROUND = QColor(20, 20, 20)  # ≈ #141414, neutral, as in the Metal app
LINE_WIDTH = 2.0  # points
FRAME_UNIFORM_SIZE = 160  # mat4 viewProjection + 6 vec4 (see common.glsl)
OBJECT_UNIFORM_SIZE = 128  # mat4 model + 4 vec4
SEGMENTS_PER_BUFFER = 1_000_000  # 32 MB: under Direct3D 11's guaranteed 128 MB per buffer

# Machine axes → Z-up display: machine Y (operator's right) → display X, machine Z (toward the
# spindle) → display Y, machine X (up) → display Z.
MACHINE_TO_DISPLAY = np.array([[0, 1, 0, 0], [0, 0, 1, 0], [1, 0, 0, 0], [0, 0, 0, 1]], float)

_CORNERS = np.array([[0, -1], [1, -1], [1, 1], [0, -1], [1, 1], [0, 1]], "<f4")

Usage = QRhiBuffer.UsageFlag
Stage = QRhiShaderResourceBinding.StageFlag
Format = QRhiVertexInputAttribute.Format
Blend = QRhiGraphicsPipeline.BlendFactor
Compare = QRhiGraphicsPipeline.CompareOp
StencilOp = QRhiGraphicsPipeline.StencilOp


def _shader(name: str) -> QShader:
    shader = QShader.fromSerialized((SHADERS / f"{name}.qsb").read_bytes())
    if not shader.isValid():
        raise RuntimeError(f"Invalid shader pack {name}.qsb; run scripts/bake_shaders.py")
    return shader


def _mat_bytes(m: np.ndarray) -> bytes:
    """Row-major numpy matrix → column-major float32 bytes (GLSL mat4)."""
    return np.ascontiguousarray(np.asarray(m, "<f4").T).tobytes()


@dataclass
class _MeshState:
    """A mesh's per-frame state (copied in synchronize)."""

    version: int
    vertices: np.ndarray
    normals: np.ndarray
    indices: np.ndarray
    uniforms: bytes
    visible: bool
    translucent: bool
    on_top: bool
    bias: float
    stencil: int


@dataclass
class _LineState:
    version: int
    segments: np.ndarray
    uniforms: bytes
    xray_uniforms: bytes | None
    visible: bool
    count: int


@dataclass
class _FrameState:
    """What the renderer needs for one frame."""

    view_projection: np.ndarray
    eye: np.ndarray
    light: np.ndarray
    up: np.ndarray
    line_width_px: float
    clip_plane: np.ndarray
    realistic: bool
    time: float


def _object_uniforms(model, color, material=None, unlit=False, xray=0.0) -> bytes:
    if material is None:
        pbr, axis = (0.0, 0.5, 0.0, 1.0), (0.0, 1.0, 0.0)
    else:
        pbr, axis = (material.metallic, material.roughness, material.pattern, material.edges), material.axis
    axis_world = (np.asarray(model, float) @ np.array([*axis, 0.0]))[:3]
    return (_mat_bytes(model) + np.asarray(color, "<f4").tobytes() + np.asarray(pbr, "<f4").tobytes()
            + np.array([*axis_world, 1.0 if unlit else 0.0], "<f4").tobytes()
            + np.array([xray, 0, 0, 0], "<f4").tobytes())


class _GpuMesh:
    def __init__(self, rhi, frame_ubuf, state: _MeshState, batch) -> None:
        self.version = state.version
        self.index_count = len(state.indices)
        self.vbuf = rhi.newBuffer(QRhiBuffer.Type.Immutable, Usage.VertexBuffer, max(state.vertices.nbytes, 12))
        self.nbuf = rhi.newBuffer(QRhiBuffer.Type.Immutable, Usage.VertexBuffer, max(state.normals.nbytes, 12))
        self.ibuf = rhi.newBuffer(QRhiBuffer.Type.Immutable, Usage.IndexBuffer, max(state.indices.nbytes, 4))
        self.ubuf = rhi.newBuffer(QRhiBuffer.Type.Dynamic, Usage.UniformBuffer, OBJECT_UNIFORM_SIZE)
        for b in (self.vbuf, self.nbuf, self.ibuf, self.ubuf):
            b.create()
        if self.index_count:
            batch.uploadStaticBuffer(self.vbuf, memoryview(state.vertices).cast("B"))
            batch.uploadStaticBuffer(self.nbuf, memoryview(state.normals).cast("B"))
            batch.uploadStaticBuffer(self.ibuf, memoryview(state.indices).cast("B"))
        self.srb = _object_srb(rhi, frame_ubuf, self.ubuf)
        self.state = state
        self.uniforms = b""

    def release(self) -> None:
        for r in (self.srb, self.vbuf, self.nbuf, self.ibuf, self.ubuf):
            r.destroy()


class _GpuLines:
    def __init__(self, rhi, frame_ubuf, state: _LineState, batch) -> None:
        self.version = state.version
        self.chunks: list[tuple[QRhiBuffer, int]] = []  # (buffer, segment count)
        seg = state.segments
        for start in range(0, len(seg), SEGMENTS_PER_BUFFER):
            part = seg[start:start + SEGMENTS_PER_BUFFER]
            buf = rhi.newBuffer(QRhiBuffer.Type.Immutable, Usage.VertexBuffer, part.nbytes)
            buf.create()
            batch.uploadStaticBuffer(buf, memoryview(part).cast("B"))
            self.chunks.append((buf, len(part)))
        self.ubuf = rhi.newBuffer(QRhiBuffer.Type.Dynamic, Usage.UniformBuffer, OBJECT_UNIFORM_SIZE)
        self.xbuf = rhi.newBuffer(QRhiBuffer.Type.Dynamic, Usage.UniformBuffer, OBJECT_UNIFORM_SIZE)
        self.ubuf.create()
        self.xbuf.create()
        self.srb = _object_srb(rhi, frame_ubuf, self.ubuf)
        self.xsrb = _object_srb(rhi, frame_ubuf, self.xbuf)
        self.state = state
        self.uniforms = b""
        self.xray_uniforms = b""

    def release(self) -> None:
        for buf, _ in self.chunks:
            buf.destroy()
        for r in (self.srb, self.xsrb, self.ubuf, self.xbuf):
            r.destroy()


def _object_srb(rhi, frame_ubuf, object_ubuf):
    both = Stage.VertexStage | Stage.FragmentStage
    srb = rhi.newShaderResourceBindings()
    srb.setBindings([QRhiShaderResourceBinding.uniformBuffer(0, both, frame_ubuf),
                     QRhiShaderResourceBinding.uniformBuffer(1, both, object_ubuf)])
    srb.create()
    return srb


def _blend() -> QRhiGraphicsPipeline.TargetBlend:
    blend = QRhiGraphicsPipeline.TargetBlend()
    blend.enable = True
    blend.srcColor, blend.dstColor = Blend.SrcAlpha, Blend.OneMinusSrcAlpha
    blend.srcAlpha, blend.dstAlpha = Blend.One, Blend.OneMinusSrcAlpha  # keep the target opaque
    return blend


def _stencil(compare, pass_op) -> QRhiGraphicsPipeline.StencilOpState:
    s = QRhiGraphicsPipeline.StencilOpState()
    s.failOp = StencilOp.Keep
    s.depthFailOp = StencilOp.Keep
    s.passOp = pass_op
    s.compareOp = compare
    return s


class _Renderer(QQuickRhiItemRenderer):
    def __init__(self) -> None:
        super().__init__()
        self._ready = False
        self._sample_count = 0
        self._frame: _FrameState | None = None
        self._meshes: dict[str, _GpuMesh] = {}
        self._lines: dict[str, _GpuLines] = {}
        self._mesh_states: dict[str, _MeshState] = {}
        self._line_states: dict[str, _LineState] = {}
        self._release: list = []
        self._pipelines: dict[tuple, QRhiGraphicsPipeline] = {}

    # ---- UI thread waits during this call

    def synchronize(self, item: "Viewport") -> None:
        self._frame = item._frame_state()
        scene = item.scene
        if scene is None:
            self._mesh_states, self._line_states = {}, {}
            return
        meshes, lines = {}, {}
        for key, m in scene.meshes.items():
            model = scene.group_transform(m.group) @ m.transform
            meshes[key] = _MeshState(m.version, m.vertices, m.normals, m.indices,
                                     _object_uniforms(model, m.color, m.material, m.unlit), m.visible, m.translucent,
                                     m.on_top, float(m.depth_bias), 1 if m.xray_through else 0)
        for key, ln in scene.lines.items():
            model = scene.group_transform(ln.group)
            lines[key] = _LineState(ln.version, ln.segments, _object_uniforms(model, (1, 1, 1, 1)),
                                    _object_uniforms(model, (1, 1, 1, 1), xray=ln.xray) if ln.xray > 0 else None,
                                    ln.visible, max(0, min(ln.visible_count, ln.count)))
        self._mesh_states, self._line_states = meshes, lines

    # ---- render thread

    def initialize(self, cb: QRhiCommandBuffer) -> None:
        rt = self.renderTarget()
        if self._ready and rt.sampleCount() == self._sample_count:
            return
        rhi = self.rhi()
        for p in self._pipelines.values():
            p.destroy()
        self._pipelines.clear()
        if not self._ready:
            self._frame_ubuf = rhi.newBuffer(QRhiBuffer.Type.Dynamic, Usage.UniformBuffer, FRAME_UNIFORM_SIZE)
            self._frame_ubuf.create()
            self._dummy_ubuf = rhi.newBuffer(QRhiBuffer.Type.Dynamic, Usage.UniformBuffer, OBJECT_UNIFORM_SIZE)
            self._dummy_ubuf.create()
            self._layout_srb = _object_srb(rhi, self._frame_ubuf, self._dummy_ubuf)
            self._corner_buf = rhi.newBuffer(QRhiBuffer.Type.Immutable, Usage.VertexBuffer, _CORNERS.nbytes)
            self._corner_buf.create()
            batch = rhi.nextResourceUpdateBatch()
            batch.uploadStaticBuffer(self._corner_buf, _CORNERS.tobytes())
            cb.resourceUpdate(batch)
        self._sample_count = rt.sampleCount()
        self._ready = True

    def _pipeline(self, kind: str, bias: float = 0.0) -> QRhiGraphicsPipeline:
        """Pipelines by kind: "opaque", "translucent", "top" (meshes) and "xray", "line"."""
        key = (kind, bias)
        p = self._pipelines.get(key)
        if p is not None:
            return p
        rhi, rt = self.rhi(), self.renderTarget()
        p = rhi.newGraphicsPipeline()
        mesh = kind in ("opaque", "translucent", "top")
        vert, frag = ("mesh.vert", "mesh.frag") if mesh else ("line.vert", "line.frag")
        p.setShaderStages([QRhiShaderStage(QRhiShaderStage.Type.Vertex, _shader(vert)),
                           QRhiShaderStage(QRhiShaderStage.Type.Fragment, _shader(frag))])
        layout = QRhiVertexInputLayout()
        if mesh:
            layout.setBindings([QRhiVertexInputBinding(12), QRhiVertexInputBinding(12)])
            layout.setAttributes([QRhiVertexInputAttribute(0, 0, Format.Float3, 0),
                                  QRhiVertexInputAttribute(1, 1, Format.Float3, 0)])
        else:
            layout.setBindings([QRhiVertexInputBinding(8),
                                QRhiVertexInputBinding(SEGMENT_DTYPE.itemsize, QRhiVertexInputBinding.Classification.PerInstance)])
            layout.setAttributes([QRhiVertexInputAttribute(0, 0, Format.Float2, 0),
                                  QRhiVertexInputAttribute(1, 1, Format.Float3, 0),
                                  QRhiVertexInputAttribute(1, 2, Format.Float3, 12),
                                  QRhiVertexInputAttribute(1, 3, Format.UNormByte4, 24),
                                  QRhiVertexInputAttribute(1, 4, Format.UNormByte4, 28)])
        p.setVertexInputLayout(layout)
        p.setShaderResourceBindings(self._layout_srb)
        p.setRenderPassDescriptor(rt.renderPassDescriptor())
        p.setSampleCount(rt.sampleCount())
        p.setTargetBlends([_blend()])
        p.setCullMode(QRhiGraphicsPipeline.CullMode.None_)
        p.setFrontFace(QRhiGraphicsPipeline.FrontFace.CCW)  # OCCT and Rhino wind front faces CCW
        p.setDepthTest(True)
        if kind == "opaque":
            p.setDepthWrite(True)
            p.setDepthOp(Compare.LessOrEqual)
            # Each opaque mesh writes its stencil value where it's the nearest: 1 for the stock
            # (x-ray toolpaths show through it), 0 for everything else.
            mark = _stencil(Compare.Always, StencilOp.Replace)
            p.setStencilTest(True)
            p.setStencilFront(mark)
            p.setStencilBack(mark)
        elif kind == "translucent":
            p.setDepthWrite(False)
            p.setDepthOp(Compare.LessOrEqual)
        elif kind == "top":
            p.setDepthWrite(False)
            p.setDepthOp(Compare.Always)
        elif kind == "xray":
            p.setDepthWrite(False)
            p.setDepthOp(Compare.Always)
            on_stock = _stencil(Compare.Equal, StencilOp.Keep)
            p.setStencilTest(True)
            p.setStencilFront(on_stock)
            p.setStencilBack(on_stock)
            p.setStencilWriteMask(0)
        else:
            p.setDepthWrite(False)
            p.setDepthOp(Compare.LessOrEqual)
        if mesh and bias:
            # Faces that touch get a fixed winner instead of flickering: positive bias pulls
            # toward the camera (smaller depth here).
            p.setDepthBias(int(-bias * 4))
            p.setSlopeScaledDepthBias(-bias * 1.0)
        if not p.create():
            raise RuntimeError(f"Could not create the {kind} pipeline")
        self._pipelines[key] = p
        return p

    def _apply_scene(self, rhi, batch) -> None:
        meshes, lines = self._mesh_states, self._line_states
        for key in list(self._meshes):
            if key not in meshes or meshes[key].version != self._meshes[key].version:
                self._release.append(self._meshes.pop(key))
        for key, state in meshes.items():
            gpu = self._meshes.get(key)
            if gpu is None:
                gpu = self._meshes[key] = _GpuMesh(rhi, self._frame_ubuf, state, batch)
            gpu.state = state
            if gpu.uniforms != state.uniforms:
                batch.updateDynamicBuffer(gpu.ubuf, 0, state.uniforms)
                gpu.uniforms = state.uniforms
        for key in list(self._lines):
            if key not in lines or lines[key].version != self._lines[key].version:
                self._release.append(self._lines.pop(key))
        for key, state in lines.items():
            gpu = self._lines.get(key)
            if gpu is None:
                gpu = self._lines[key] = _GpuLines(rhi, self._frame_ubuf, state, batch)
            gpu.state = state
            if gpu.uniforms != state.uniforms:
                batch.updateDynamicBuffer(gpu.ubuf, 0, state.uniforms)
                gpu.uniforms = state.uniforms
            if state.xray_uniforms is not None and gpu.xray_uniforms != state.xray_uniforms:
                batch.updateDynamicBuffer(gpu.xbuf, 0, state.xray_uniforms)
                gpu.xray_uniforms = state.xray_uniforms

    def render(self, cb: QRhiCommandBuffer) -> None:
        rhi = self.rhi()
        for gpu in self._release:
            gpu.release()
        self._release.clear()
        batch = rhi.nextResourceUpdateBatch()
        self._apply_scene(rhi, batch)
        rt = self.renderTarget()
        size = rt.pixelSize()
        w, h = max(size.width(), 1), max(size.height(), 1)
        f = self._frame
        if f is not None:
            corr = np.array(rhi.clipSpaceCorrMatrix().data(), float).reshape(4, 4).T
            frame = (_mat_bytes(corr @ f.view_projection)
                     + np.array([*f.eye, 1.0, *f.light, 0.0, w, h, f.line_width_px, f.time, *f.clip_plane,
                                 *f.up, 0.0, 1.0 if f.realistic else 0.0, 0.0, 0.0, 0.0], "<f4").tobytes())
            batch.updateDynamicBuffer(self._frame_ubuf, 0, frame)
        cb.beginPass(rt, BACKGROUND, QRhiDepthStencilClearValue(1.0, 0), batch)
        if f is not None:
            cb.setViewport(QRhiViewport(0, 0, w, h))
            visible = [m for m in self._meshes.values() if m.state.visible and m.index_count]
            ordered = ([m for m in visible if not m.state.translucent and not m.state.on_top]
                       + [m for m in visible if m.state.translucent and not m.state.on_top]
                       + [m for m in visible if m.state.on_top])
            current = None
            for m in ordered:
                kind = "top" if m.state.on_top else "translucent" if m.state.translucent else "opaque"
                p = self._pipeline(kind, m.state.bias)
                if p is not current:
                    cb.setGraphicsPipeline(p)
                    current = p
                if kind == "opaque":
                    cb.setStencilRef(m.state.stencil)
                cb.setShaderResources(m.srb)
                cb.setVertexInput(0, [(m.vbuf, 0), (m.nbuf, 0)], m.ibuf, 0, QRhiCommandBuffer.IndexFormat.IndexUInt32)
                cb.drawIndexed(m.index_count)
            lines = [ln for ln in self._lines.values() if ln.state.visible and ln.state.count > 0]
            xray = [ln for ln in lines if ln.state.xray_uniforms is not None]
            if xray:
                cb.setGraphicsPipeline(self._pipeline("xray"))
                cb.setStencilRef(1)
                for ln in xray:
                    self._draw_lines(cb, ln, ln.xsrb)
            if lines:
                cb.setGraphicsPipeline(self._pipeline("line"))
                for ln in lines:
                    self._draw_lines(cb, ln, ln.srb)
        cb.endPass()

    def _draw_lines(self, cb, ln: _GpuLines, srb) -> None:
        cb.setShaderResources(srb)
        remaining = ln.state.count
        for buf, count in ln.chunks:
            n = min(count, remaining)
            if n <= 0:
                break
            cb.setVertexInput(0, [(self._corner_buf, 0), (buf, 0)])
            cb.draw(6, n)
            remaining -= n


@QmlElement
class Viewport(QQuickRhiItem):
    """The 3D view. Drag: orbit · right/middle/Alt-drag or two-finger scroll: pan · wheel or
    pinch: zoom · double-click: frame everything. A click without dragging reports `clicked`
    with the world point under it (picking)."""

    sceneChanged = Signal()
    cameraChanged = Signal()
    realisticChanged = Signal()
    perspectiveChanged = Signal()
    clicked = Signal(float, float)  # item coordinates of a click (no drag)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setSampleCount(4)
        self.setAcceptedMouseButtons(Qt.MouseButton.AllButtons)
        self.setAcceptHoverEvents(True)
        self.camera = OrbitCamera()
        self.world_to_display = np.identity(4)
        self._scene: Scene | None = None
        self._realistic = False
        self._drag: tuple[QPointF, bool] | None = None
        self._moved = False
        self._animation: tuple[OrbitCamera, OrbitCamera, float, float] | None = None
        self.animations_enabled = True
        self._start = time.monotonic()
        self._last_camera: OrbitCamera | None = None
        self.on_camera_change = None  # callback(camera)

    def createRenderer(self) -> QQuickRhiItemRenderer:
        # Keep a reference: PySide leaves the renderer owned by Python, so without it the
        # renderer is garbage-collected while Qt still uses it (the window then hangs).
        self._renderer = _Renderer()
        return self._renderer

    # ---- scene

    def _get_scene(self) -> Scene | None:
        return self._scene

    def _set_scene(self, scene: Scene | None) -> None:
        if scene is self._scene:
            return
        if self._scene is not None:
            self._scene.changed.disconnect(self._redraw)
            self._scene.frameRequested.disconnect(self.frameAll)
        self._scene = scene
        if scene is not None:
            # Slots of this item: Qt drops the connections when the item is deleted (its page closed).
            scene.changed.connect(self._redraw)
            scene.frameRequested.connect(self.frameAll)
        self.update()
        self.sceneChanged.emit()

    scene = Property(QObject, _get_scene, _set_scene, notify=sceneChanged)

    @Slot()
    def _redraw(self) -> None:
        self.update()

    def _get_realistic(self) -> bool:
        return self._realistic

    def _set_realistic(self, on: bool) -> None:
        if on != self._realistic:
            self._realistic = bool(on)
            self.realisticChanged.emit()
            self.update()

    realistic = Property(bool, _get_realistic, _set_realistic, notify=realisticChanged)

    def _get_perspective(self) -> bool:
        return not self.camera.orthographic

    def _set_perspective(self, on: bool) -> None:
        if self.camera.orthographic == bool(on):
            self.move_camera(lambda c: setattr(c, "orthographic", not on), animated=False)
            self.perspectiveChanged.emit()

    perspective = Property(bool, _get_perspective, _set_perspective, notify=perspectiveChanged)

    # ---- camera moves

    @property
    def destination_camera(self) -> OrbitCamera:
        return self._animation[1] if self._animation is not None else self.camera

    def move_camera(self, change, animated: bool = True, duration: float | None = None) -> None:
        """Changes the camera, easing from the current view when animated."""
        to = self.destination_camera.copy()
        change(to)
        if not (animated and self.animations_enabled) or to.same_as(self.camera):
            self._animation = None
            self.camera = to
            self.update()
            return
        while to.yaw - self.camera.yaw > math.pi:
            to.yaw -= 2 * math.pi
        while to.yaw - self.camera.yaw < -math.pi:
            to.yaw += 2 * math.pi
        angle = abs(to.yaw - self.camera.yaw) + abs(to.pitch - self.camera.pitch)
        d = duration if duration is not None else 0.5 + 0.45 * min(angle / math.pi, 1)
        self._animation = (self.camera.copy(), to, time.monotonic(), d)
        self.update()

    def cancel_camera_animation(self) -> None:
        self._animation = None

    def _step_animation(self) -> bool:
        a = self._animation
        if a is None:
            return False
        frm, to, start, duration = a
        t = min((time.monotonic() - start) / duration, 1.0)
        e = 0.5 - 0.5 * math.cos(math.pi * t)
        c = to.copy()
        c.yaw = frm.yaw + (to.yaw - frm.yaw) * e
        c.pitch = frm.pitch + (to.pitch - frm.pitch) * e
        c.target = frm.target + (to.target - frm.target) * e
        c.distance = frm.distance * math.pow(to.distance / max(frm.distance, 1e-3), e)
        c.scene_radius = max(frm.scene_radius, to.scene_radius)
        self.camera = c
        if t >= 1:
            self._animation = None
        return True

    def _display_box(self, lo, hi) -> tuple[np.ndarray, np.ndarray]:
        corners = np.array([[x, y, z, 1.0] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])])
        d = (self.world_to_display @ corners.T).T[:, :3]
        return d.min(0), d.max(0)

    @Slot()
    def frameAll(self) -> None:
        self.frame_all(animated=False)

    def frame_all(self, animated: bool = False) -> None:
        bounds = self._scene.visible_bounds() if self._scene is not None else None
        if bounds is not None:
            lo, hi = self._display_box(*bounds)
            self.move_camera(lambda c: c.frame(lo, hi), animated)

    def frame_world(self, lo, hi, animated: bool = False) -> None:
        dlo, dhi = self._display_box(lo, hi)
        self.move_camera(lambda c: c.frame(dlo, dhi), animated)

    @Slot(str)
    def setView(self, view: str) -> None:
        self.move_camera(lambda c: c.set_view(view), animated=True)

    def set_pivot(self, world) -> None:
        """Orbits around this world point (None: the view target)."""
        if world is None:
            self.camera.pivot = None
        else:
            self.camera.pivot = (self.world_to_display @ np.array([*world, 1.0]))[:3]

    # ---- frame

    def _frame_state(self) -> _FrameState:
        animating = self._step_animation()
        cam = self.camera
        size = self.effectiveColorBufferSize()
        aspect = size.width() / max(size.height(), 1) if size.width() > 0 else max(self.width(), 1) / max(self.height(), 1)
        eye = cam.eye
        to_eye = (eye - cam.target) / np.linalg.norm(eye - cam.target)
        right = np.cross(to_eye, [0.0, 0.0, 1.0])
        right /= max(np.linalg.norm(right), 1e-9)
        light = to_eye + 0.6 * right + np.array([0.0, 0.0, 1.2])  # over the viewer's right shoulder
        light /= np.linalg.norm(light)
        inv = np.linalg.inv(self.world_to_display)
        window = self.window()
        dpr = window.effectiveDevicePixelRatio() if window is not None else 1.0
        clip = self._scene.clip_plane if self._scene is not None else np.zeros(4)
        state = _FrameState(cam.view_projection(aspect) @ self.world_to_display, (inv @ np.array([*eye, 1.0]))[:3],
                            (inv @ np.array([*light, 0.0]))[:3], (inv @ np.array([0.0, 0.0, 1.0, 0.0]))[:3],
                            LINE_WIDTH * dpr, clip, self._realistic, time.monotonic() - self._start)
        if animating:
            QTimer.singleShot(0, self, self._redraw)
        if self._last_camera is None or not self._last_camera.same_as(cam):
            self._last_camera = cam.copy()
            QTimer.singleShot(0, self, self._camera_moved)
        return state

    @Slot()
    def _camera_moved(self) -> None:
        self.cameraChanged.emit()
        if self.on_camera_change is not None:
            self.on_camera_change(self.camera)

    # ---- picking

    def ray(self, x: float, y: float) -> tuple[np.ndarray, np.ndarray]:
        """The world-space ray under a point in the item (origin top-left)."""
        w, h = max(self.width(), 1), max(self.height(), 1)
        inv = np.linalg.inv(self.camera.view_projection(w / h) @ self.world_to_display)
        nx, ny = x / w * 2 - 1, 1 - y / h * 2
        a = inv @ np.array([nx, ny, -1.0, 1.0])
        b = inv @ np.array([nx, ny, 1.0, 1.0])
        a, b = a[:3] / a[3], b[:3] / b[3]
        d = b - a
        return a, d / np.linalg.norm(d)

    def pick(self, x: float, y: float):
        """The nearest pickable mesh under a point: (id, world point, local point) or None."""
        if self._scene is None:
            return None
        o, d = self.ray(x, y)
        return self._scene.pick(o, d)

    def project(self, world) -> tuple[float, float] | None:
        """Item coordinates of a world point (labels over the view), None when behind the eye."""
        w, h = max(self.width(), 1), max(self.height(), 1)
        p = self.camera.view_projection(w / h) @ self.world_to_display @ np.array([*world, 1.0])
        if p[3] <= 1e-9:
            return None
        return float((p[0] / p[3] * 0.5 + 0.5) * w), float((0.5 - p[1] / p[3] * 0.5) * h)

    # ---- input

    def mousePressEvent(self, event) -> None:
        panning = (event.button() in (Qt.MouseButton.RightButton, Qt.MouseButton.MiddleButton)
                   or bool(event.modifiers() & Qt.KeyboardModifier.AltModifier))
        handler = getattr(self, "drag_handler", None)
        if not panning and event.button() == Qt.MouseButton.LeftButton and handler is not None:
            if handler.begin(event.position().x(), event.position().y()):
                self._handle_drag = True  # a handle or an object takes this drag, not the camera
                self._drag = None
                event.accept()
                return
        self._handle_drag = False
        self._drag = (event.position(), panning)
        self._moved = False
        self.cancel_camera_animation()
        event.accept()

    def mouseMoveEvent(self, event) -> None:
        if getattr(self, "_handle_drag", False):
            self.drag_handler.move(event.position().x(), event.position().y())
            return
        if self._drag is None:
            return
        last, panning = self._drag
        d = event.position() - last
        if abs(d.x()) + abs(d.y()) > 0.5:
            self._moved = True
        if panning:
            self.camera.pan(d.x(), d.y(), self.height())
        else:
            self.camera.orbit(d.x(), d.y())
        self._drag = (event.position(), panning)
        self.update()

    def mouseReleaseEvent(self, event) -> None:
        if getattr(self, "_handle_drag", False):
            self._handle_drag = False
            self.drag_handler.end()
            return
        if self._drag is not None and not self._moved and event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit(event.position().x(), event.position().y())
        self._drag = None

    def mouseDoubleClickEvent(self, event) -> None:
        self.frame_all(animated=True)

    def wheelEvent(self, event) -> None:
        pixels = event.pixelDelta()
        ctrl = bool(event.modifiers() & Qt.KeyboardModifier.ControlModifier)
        self.cancel_camera_animation()
        if not pixels.isNull() and not ctrl:
            self.camera.pan(pixels.x(), pixels.y(), self.height())  # trackpad two-finger scroll pans
        else:
            steps = event.angleDelta().y() / 120.0  # mouse wheel, or Ctrl + scroll (Windows pinch), zooms
            self.camera.zoom(math.pow(0.85, steps))
        self.update()
        event.accept()

    def event(self, event) -> bool:
        if event.type() == event.Type.NativeGesture and event.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            self.camera.zoom(1.0 / max(1.0 + event.value(), 0.1))  # macOS pinch
            self.update()
            return True
        return super().event(event)

    # ---- snapshots

    def snapshot(self, path: str | Path, width: int, height: int, done=None) -> None:
        """Writes a PNG of the view (guided-step images). `done(ok)` is called when written."""
        result = self.grabToImage(QSize(width, height))
        if result is None:
            if done:
                done(False)
            return
        self._grab = result

        def ready() -> None:
            ok = result.saveToFile(str(path))
            self._grab = None
            if done:
                done(ok)

        result.ready.connect(ready)
