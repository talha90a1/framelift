# SPDX-License-Identifier: AGPL-3.0-only
"""Rebuild the bundled DualSense model with Blender's Python module (bpy 5.1)."""

from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import urlretrieve

import bpy

MODEL_URL = (
    "https://raw.githubusercontent.com/StonedModder/dualsense-controller/"
    "f9ab38fb25d3ce5bce6f6404c5ab51f9a4ae1eac/controller/dualsense.glb"
)


def material(name, gray, roughness):
    result = bpy.data.materials.new(name)
    color = (gray, gray, gray, 1)
    result.diffuse_color = color
    result.use_nodes = True
    shader = result.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    return result


def build(source, output):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(source))
    shell = material("Shell", 0.69, 0.35)
    touchpad = material("Touchpad", 0.54, 0.60)
    grip = material("Grip", 0.024, 0.47)
    controls = material("Controls", 0.10, 0.40)
    faces = material("FaceButtons", 0.48, 0.33)
    lightbar = material("LightBar", 0.035, 0.37)

    for obj in list(bpy.data.objects):
        if obj.type != "MESH":
            continue
        name = obj.name
        if "ps__logo" in name or "decal" in name:
            bpy.data.objects.remove(obj, do_unlink=True)
            continue
        if name.startswith("lights__touchpad-surround"):
            obj.name = "LightBar"
            obj.data.name = "LightBarSurface"
            finish = lightbar
        elif name.startswith("create__button"):
            obj.name = "CreateButton"
            finish = faces
        elif name.startswith("ps__button-base"):
            obj.name = "PSButton"
            finish = controls
        elif name.startswith(("white-shell", "back-shell")):
            finish = shell
        elif name.startswith("touchpad"):
            finish = touchpad
        elif name.startswith(("triangle", "square", "cross", "circle", "options")):
            finish = faces
        elif any(
            part in name
            for part in ("black-front", "stick-well", "ps-mount", "mute-mount")
        ):
            finish = grip
        else:
            finish = controls
        obj.data.materials.clear()
        obj.data.materials.append(finish)

    bpy.ops.wm.usd_export(
        filepath=str(output),
        export_uvmaps=False,
        export_custom_properties=False,
        convert_orientation=True,
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        root_prim_path="/Pairing",
    )


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    with TemporaryDirectory(prefix="framelift-model-") as stage:
        source = Path(stage) / "dualsense.glb"
        urlretrieve(MODEL_URL, source)
        build(source, root / "Sources/Framelift/App/DualSensePairing.usdz")
