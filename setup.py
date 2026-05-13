import os
import platform
from setuptools import setup, Extension

zyaml_dir = os.path.dirname(os.path.abspath(__file__))
static_lib = os.path.join(zyaml_dir, "zig-out", "lib", "libzyaml_c.a")

link_args = ["-lc"]
if platform.system() == "Linux":
    link_args.extend(["-lunwind", "-lpthread", "-ldl"])

ext = Extension(
    "zyaml._ext",
    sources=["python/zyaml/_ext.c"],
    extra_objects=[static_lib],
    extra_link_args=link_args,
)

setup(ext_modules=[ext])
