import os
import sys
from setuptools import setup, Extension

zyaml_dir = os.path.dirname(os.path.abspath(__file__))

if sys.platform == "win32":
    static_lib = os.path.join(zyaml_dir, "zig-out", "lib", "zyaml_c.lib")
    extra_link_args = []
else:
    static_lib = os.path.join(zyaml_dir, "zig-out", "lib", "libzyaml_c.a")
    extra_link_args = ["-lc"]

ext = Extension(
    "zyaml._ext",
    sources=["python/zyaml/_ext.c"],
    extra_objects=[static_lib],
    extra_link_args=extra_link_args,
)

setup(ext_modules=[ext])
