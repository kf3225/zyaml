"""
zyaml - Python bindings for zyaml (YAML 1.2.2 parser in Zig)

PyYAML-compatible API:
    import zyaml

    data = zyaml.safe_load("a: 1")
    print(zyaml.safe_dump(data))
"""

import ctypes
import dataclasses
import io
import os
import warnings
from enum import IntEnum
from typing import Any, Iterator, TypeVar, Union, overload

import zyaml._ext as _ext  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Error classes
# ---------------------------------------------------------------------------


class YAMLError(Exception):
    pass


class MarkedYAMLError(YAMLError):
    def __init__(self, context=None, context_mark=None, problem=None, problem_mark=None, note=None):
        self.context = context
        self.context_mark = context_mark
        self.problem = problem
        self.problem_mark = problem_mark
        self.note = note
        super().__init__(self._compose_message())

    def _compose_message(self):
        parts = []
        if self.context is not None:
            parts.append(self.context)
        if self.context_mark is not None:
            parts.append(str(self.context_mark))
        if self.problem is not None:
            parts.append(self.problem)
        if self.problem_mark is not None:
            parts.append(str(self.problem_mark))
        if self.note is not None:
            parts.append(self.note)
        return "\n".join(parts) if parts else "YAML error"


class Mark:
    def __init__(self, name, index, line, column, buffer=None, pointer=None):
        self.name = name
        self.index = index
        self.line = line
        self.column = column
        self.buffer = buffer
        self.pointer = pointer

    def get_snippet(self, indent=4, max_length=75):
        return None

    def __str__(self):
        return f'  in "{self.name}", line {self.line + 1}, column {self.column + 1}'


# ---------------------------------------------------------------------------
# Loader / Dumper stubs (PyYAML-compatible)
# ---------------------------------------------------------------------------

# reason: PyYAML-compatible API surface — definition enumeration


class BaseLoader:
    def __init__(self, stream):
        self.stream = stream


class SafeLoader:
    def __init__(self, stream):
        self.stream = stream


class FullLoader:
    def __init__(self, stream):
        self.stream = stream


class Loader:
    def __init__(self, stream):
        self.stream = stream


class UnsafeLoader:
    def __init__(self, stream):
        self.stream = stream


class BaseDumper:
    def __init__(self, stream, **kwargs):
        self.stream = stream
        for k, v in kwargs.items():
            setattr(self, k, v)


class SafeDumper(BaseDumper):
    pass


class Dumper(BaseDumper):
    pass


DEFAULT_MAPPING_TAG = "tag:yaml.org,2002:map"
DEFAULT_SEQUENCE_TAG = "tag:yaml.org,2002:seq"
DEFAULT_SCALAR_TAG = "tag:yaml.org,2002:str"


# ---------------------------------------------------------------------------
# Dump options
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class _DumpOpts:
    indent: int = 2
    flow: bool = False
    sort_keys: bool = True
    explicit_start: bool = False
    explicit_end: bool = False

    @staticmethod
    def from_kwargs(
        default_flow_style=False,
        indent=None,
        sort_keys=True,
        explicit_start=False,
        explicit_end=False,
        **_ignore,
    ) -> "_DumpOpts":
        return _DumpOpts(
            indent=indent if indent is not None else 2,
            flow=default_flow_style,
            sort_keys=sort_keys,
            explicit_start=explicit_start,
            explicit_end=explicit_end,
        )


# ---------------------------------------------------------------------------
# C library loading (low-level API for YamlValue)
# ---------------------------------------------------------------------------

# reason: ctypes binding definitions — definition enumeration, exempt from line limits


class YamlType(IntEnum):
    NULL = 0
    BOOLEAN = 1
    INTEGER = 2
    FLOAT = 3
    STRING = 4
    SEQUENCE = 5
    MAPPING = 6


_LIB_NAMES = ["libzyaml.so", "libzyaml.dylib", "zyaml.dll"]


def _find_lib() -> str:
    this_dir = os.path.dirname(os.path.abspath(__file__))
    found = _search_dir(this_dir)
    if found:
        return found
    build_dir = os.path.join(os.path.normpath(os.path.join(this_dir, "..", "..")), "zig-out", "lib")
    found = _search_dir(build_dir)
    if found:
        return found
    raise FileNotFoundError(
        f"zyaml shared library not found. Run 'zig build' first. Searched: {this_dir}, {build_dir}"
    )


def _search_dir(directory: str) -> str | None:
    for name in _LIB_NAMES:
        path = os.path.join(directory, name)
        if os.path.exists(path):
            return path
    return None


def _init_lib() -> ctypes.CDLL:
    lib = ctypes.CDLL(_find_lib())
    _setup_parse_api(lib)
    _setup_value_api(lib)
    _setup_collection_api(lib)
    _setup_string_api(lib)
    return lib


def _setup_parse_api(lib: ctypes.CDLL) -> None:
    lib.zyaml_parse.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    lib.zyaml_parse.restype = ctypes.c_void_p
    lib.zyaml_parse_file.argtypes = [ctypes.c_char_p]
    lib.zyaml_parse_file.restype = ctypes.c_void_p
    lib.zyaml_free.argtypes = [ctypes.c_void_p]
    lib.zyaml_free.restype = None
    lib.zyaml_error_message.argtypes = []
    lib.zyaml_error_message.restype = ctypes.c_void_p


def _setup_value_api(lib: ctypes.CDLL) -> None:
    lib.zyaml_type.argtypes = [ctypes.c_void_p]
    lib.zyaml_type.restype = ctypes.c_int
    lib.zyaml_as_bool.argtypes = [ctypes.c_void_p]
    lib.zyaml_as_bool.restype = ctypes.c_bool
    lib.zyaml_as_integer.argtypes = [ctypes.c_void_p]
    lib.zyaml_as_integer.restype = ctypes.c_int64
    lib.zyaml_as_float.argtypes = [ctypes.c_void_p]
    lib.zyaml_as_float.restype = ctypes.c_double
    lib.zyaml_as_string.argtypes = [ctypes.c_void_p]
    lib.zyaml_as_string.restype = ctypes.c_void_p
    lib.zyaml_free_string.argtypes = [ctypes.c_void_p]
    lib.zyaml_free_string.restype = None


def _setup_collection_api(lib: ctypes.CDLL) -> None:
    lib.zyaml_sequence_len.argtypes = [ctypes.c_void_p]
    lib.zyaml_sequence_len.restype = ctypes.c_size_t
    lib.zyaml_sequence_get.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.zyaml_sequence_get.restype = ctypes.c_void_p
    lib.zyaml_sequence_get_borrow.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.zyaml_sequence_get_borrow.restype = ctypes.c_void_p
    lib.zyaml_mapping_len.argtypes = [ctypes.c_void_p]
    lib.zyaml_mapping_len.restype = ctypes.c_size_t
    lib.zyaml_mapping_get.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.zyaml_mapping_get.restype = ctypes.c_void_p
    lib.zyaml_mapping_get_borrow.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.zyaml_mapping_get_borrow.restype = ctypes.c_void_p
    lib.zyaml_mapping_get_key.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.zyaml_mapping_get_key.restype = ctypes.c_void_p
    lib.zyaml_mapping_get_key_borrow.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.zyaml_mapping_get_key_borrow.restype = ctypes.c_void_p
    lib.zyaml_mapping_get_value_borrow.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.zyaml_mapping_get_value_borrow.restype = ctypes.c_void_p


def _setup_string_api(lib: ctypes.CDLL) -> None:
    lib.zyaml_stringify.argtypes = [ctypes.c_void_p]
    lib.zyaml_stringify.restype = ctypes.c_void_p
    lib.zyaml_to_json.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
    lib.zyaml_to_json.restype = ctypes.c_void_p
    lib.zyaml_free_json.argtypes = [ctypes.c_void_p]
    lib.zyaml_free_json.restype = None


_lib: ctypes.CDLL | None = None


def _get_lib() -> ctypes.CDLL:
    global _lib
    if _lib is None:
        _lib = _init_lib()
    return _lib


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _read_cstr(ptr) -> str:
    if not ptr:
        return ""
    addr: int = ptr if isinstance(ptr, int) else ctypes.cast(ptr, ctypes.c_void_p).value or 0
    if addr == 0:
        return ""
    return ctypes.string_at(addr).decode("utf-8")


def _read_borrowed(ptr: int, length: int) -> str:
    if length == 0:
        return ""
    return ctypes.string_at(ptr, length).decode("utf-8")


def _value_to_python(ptr: int) -> Any:
    t = _get_lib().zyaml_type(ptr)
    if t == YamlType.STRING:
        return _read_cstr(_get_lib().zyaml_as_string(ptr))
    if t == YamlType.SEQUENCE:
        return _seq_to_python(ptr)
    if t == YamlType.MAPPING:
        return _mapping_to_python(ptr)
    if t == YamlType.NULL:
        return None
    if t == YamlType.BOOLEAN:
        return bool(_get_lib().zyaml_as_bool(ptr))
    if t == YamlType.INTEGER:
        return int(_get_lib().zyaml_as_integer(ptr))
    if t == YamlType.FLOAT:
        return float(_get_lib().zyaml_as_float(ptr))
    return None


def _seq_to_python(ptr: int) -> list[Any]:
    n = _get_lib().zyaml_sequence_len(ptr)
    return [_value_to_python(_get_lib().zyaml_sequence_get_borrow(ptr, i)) for i in range(n)]


def _mapping_to_python(ptr: int) -> dict[str, Any]:
    n = _get_lib().zyaml_mapping_len(ptr)
    out_len = ctypes.c_size_t(0)
    result: dict[str, Any] = {}
    for i in range(n):
        kp = _get_lib().zyaml_mapping_get_key_borrow(ptr, i, ctypes.byref(out_len))
        key = _read_borrowed(kp, out_len.value)
        vp = _get_lib().zyaml_mapping_get_value_borrow(ptr, i)
        result[key] = _value_to_python(vp)
    return result


def _parse_to_python(content: str | bytes) -> Any:
    try:
        if isinstance(content, bytes):
            content = content.decode("utf-8")
        return _ext.load(content)
    except RuntimeError as e:
        raise YAMLError(str(e)) from e


def _get_stream_data(stream) -> str | bytes:
    if isinstance(stream, str):
        return stream
    if isinstance(stream, bytes):
        return stream
    if hasattr(stream, "read"):
        return _read_stream(stream)
    raise TypeError(f"expected str, bytes, or file-like object, got {type(stream).__name__}")


def _read_stream(stream) -> str | bytes:
    data = stream.read()
    return data


# ---------------------------------------------------------------------------
# Dump logic
# ---------------------------------------------------------------------------


def _dump_to_string(data: Any, opts: _DumpOpts) -> str:
    flow = 1 if opts.flow else 0
    try:
        result = _ext.dump(data, indent=opts.indent, sort_keys=opts.sort_keys, flow=flow)
    except RuntimeError as e:
        raise YAMLError(str(e)) from e
    if opts.explicit_start:
        result = "---\n" + result
    if opts.explicit_end:
        result = result.rstrip("\n") + "\n...\n"
    return result


def _write_stream(stream: io.IOBase, output: str) -> None:
    if isinstance(stream, io.RawIOBase):
        stream.write(output.encode("utf-8"))  # type: ignore[arg-type]
    else:
        stream.write(output)


def _dump(data: Any, stream: io.IOBase | None = None, **kwds) -> str | None:
    opts = _DumpOpts.from_kwargs(**kwds)
    output = _dump_to_string(data, opts)
    if stream is not None:
        _write_stream(stream, output)
        return None
    return output


def _dump_all(documents: Any, stream: io.IOBase | None = None, **kwds) -> str | None:
    opts = _DumpOpts.from_kwargs(explicit_start=True, **kwds)
    parts = [_dump_to_string(doc, opts).rstrip("\n") for doc in documents]
    output = "\n".join(parts) + "\n"
    if stream is not None:
        _write_stream(stream, output)
        return None
    return output


# ---------------------------------------------------------------------------
# Coerce (type casting for generics)
# ---------------------------------------------------------------------------


T = TypeVar("T")


def _coerce(value: Any, target: type) -> Any:
    if target is Any or target is type(None):
        return value
    origin = getattr(target, "__origin__", None)
    args = getattr(target, "__args__", None)
    if origin is dict or target is dict:
        return _coerce_dict(value, args)
    if origin is list or target is list:
        return _coerce_list(value, args)
    if origin is tuple or target is tuple:
        return _coerce_tuple(value, args)
    if isinstance(target, type) and isinstance(value, dict):
        return _coerce_to_class(value, target)
    if isinstance(target, type):
        return value if isinstance(value, target) else target(value)
    return value


def _coerce_dict(value: Any, args: tuple | None) -> dict:
    if not isinstance(value, dict):
        raise TypeError(f"expected dict, got {type(value).__name__}")
    if not args or len(args) < 2:
        return value
    val_type = args[1]
    return {k: _coerce(v, val_type) for k, v in value.items()}


def _coerce_list(value: Any, args: tuple | None) -> list:
    if not isinstance(value, list):
        raise TypeError(f"expected list, got {type(value).__name__}")
    if not args:
        return value
    return [_coerce(item, args[0]) for item in value]


def _coerce_tuple(value: Any, args: tuple | None) -> tuple:
    if not isinstance(value, (list, tuple)):
        raise TypeError(f"expected sequence, got {type(value).__name__}")
    if not args:
        return tuple(value)
    if len(args) == 2 and args[1] is ...:
        return tuple(_coerce(item, args[0]) for item in value)
    return tuple(_coerce(item, t) for item, t in zip(value, args))


def _coerce_to_class(value: dict, target: type) -> Any:
    if hasattr(target, "__dataclass_fields__"):
        return _coerce_dataclass(value, target)
    return target(**value)


def _coerce_dataclass(value: dict, target: type) -> Any:
    import dataclasses as dc

    fields = dc.fields(target)
    kwargs = {}
    for f in fields:
        if f.name not in value:
            continue
        ftype = f.type
        kwargs[f.name] = value[f.name] if isinstance(ftype, str) else _coerce(value[f.name], ftype)
    return target(**kwargs)


# ---------------------------------------------------------------------------
# PyYAML-compatible public API
# ---------------------------------------------------------------------------

_Stream = str | bytes | io.IOBase


@overload
def safe_load(stream: _Stream, /) -> Any: ...
@overload
def safe_load(stream: _Stream, /, *, type: type[T]) -> T: ...


def safe_load(stream, /, *, type: type | None = None):
    data = _get_stream_data(stream)
    result = _parse_to_python(data)
    if type is not None:
        return _coerce(result, type)
    return result


def safe_load_all(stream) -> Iterator:
    data = _get_stream_data(stream)
    if isinstance(data, bytes):
        data = data.decode("utf-8")
    if not data.strip():
        return
    for doc in data.split("\n---"):
        doc = doc.strip()
        if doc:
            yield _parse_to_python(doc)


@overload
def load(stream, /) -> Any: ...
@overload
def load(stream, /, *, Loader: type) -> Any: ...
@overload
def load(stream, /, *, Loader: type, type: type[T]) -> T: ...


def load(stream, /, *, Loader=None, type: type | None = None):
    if Loader is None:
        _warn_no_loader()
    if type is not None:
        return safe_load(stream, type=type)
    return safe_load(stream)


def _warn_no_loader() -> None:
    warnings.warn(
        "Calling yaml.load() without Loader=... is deprecated. "
        "Use yaml.safe_load() or yaml.load(stream, Loader=SafeLoader).",
        DeprecationWarning,
        stacklevel=3,
    )
    raise TypeError("load() missing 1 required positional argument: 'Loader'")


def load_all(stream, Loader=None):
    if Loader is None:
        warnings.warn(
            "Calling yaml.load_all() without Loader=... is deprecated.",
            DeprecationWarning,
            stacklevel=2,
        )
        raise TypeError("load_all() missing 1 required positional argument: 'Loader'")
    return safe_load_all(stream)


def full_load(stream, /, *, type: type | None = None) -> Any:
    if type is not None:
        return safe_load(stream, type=type)
    return safe_load(stream)


def full_load_all(stream) -> Iterator:
    return safe_load_all(stream)


def unsafe_load(stream, /, *, type: type | None = None) -> Any:
    if type is not None:
        return safe_load(stream, type=type)
    return safe_load(stream)


def unsafe_load_all(stream) -> Iterator:
    return safe_load_all(stream)


@overload
def safe_dump(data: Any, /, **kwds: object) -> str: ...
@overload
def safe_dump(data: Any, /, stream: io.IOBase, **kwds: object) -> None: ...


def safe_dump(data, stream=None, **kwds) -> str | None:
    return _dump(data, stream, **kwds)


@overload
def safe_dump_all(documents: Any, /, **kwds: object) -> str: ...
@overload
def safe_dump_all(documents: Any, /, stream: io.IOBase, **kwds: object) -> None: ...


def safe_dump_all(documents, stream=None, **kwds) -> str | None:
    return _dump_all(documents, stream, **kwds)


@overload
def dump(data: Any, /, **kwds: object) -> str: ...
@overload
def dump(data: Any, /, stream: io.IOBase, **kwds: object) -> None: ...


def dump(data, stream=None, Dumper=None, **kwds) -> str | None:
    if Dumper is None:
        Dumper = SafeDumper
    return _dump(data, stream, **kwds)


@overload
def dump_all(documents: Any, /, **kwds: object) -> str: ...
@overload
def dump_all(documents: Any, /, stream: io.IOBase, **kwds: object) -> None: ...


def dump_all(documents, stream=None, Dumper=None, **kwds) -> str | None:
    if Dumper is None:
        Dumper = SafeDumper
    return _dump_all(documents, stream, **kwds)


# ---------------------------------------------------------------------------
# No-op stubs (PyYAML-compatible)
# ---------------------------------------------------------------------------


def add_constructor(tag, constructor, Loader=None):
    pass


def add_representer(data_type, representer, Dumper=None):
    pass


def add_multi_constructor(tag_prefix, multi_constructor, Loader=None):
    pass


def add_multi_representer(data_type, multi_representer, Dumper=None):
    pass


def add_implicit_resolver(tag, regexp, first=None, Loader=None, Dumper=None):
    pass


def add_path_resolver(tag, path, kind=None, Loader=None, Dumper=None):
    pass


# ---------------------------------------------------------------------------
# Low-level zyaml-specific API
# ---------------------------------------------------------------------------


class YamlValue:
    __slots__ = ("_ptr",)

    def __init__(self, ptr: int):
        self._ptr = ptr

    def __del__(self):
        if self._ptr:
            _get_lib().zyaml_free(self._ptr)
            self._ptr = 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.__del__()

    @property
    def type(self) -> YamlType:
        return YamlType(_get_lib().zyaml_type(self._ptr))

    def to_python(self) -> Any:
        return _value_to_python(self._ptr)

    def __len__(self) -> int:
        if self.type == YamlType.SEQUENCE:
            return _get_lib().zyaml_sequence_len(self._ptr)
        if self.type == YamlType.MAPPING:
            return _get_lib().zyaml_mapping_len(self._ptr)
        return 0

    def __getitem__(self, key: Union[int, str]) -> "YamlValue":
        if self.type == YamlType.SEQUENCE and isinstance(key, int):
            return self._get_seq_item(key)
        if self.type == YamlType.MAPPING and isinstance(key, str):
            return self._get_map_item(key)
        raise TypeError(f"Cannot index {self.type.name} with {type(key).__name__}")

    def _get_seq_item(self, index: int) -> "YamlValue":
        ptr = _get_lib().zyaml_sequence_get(self._ptr, index)
        if not ptr:
            raise IndexError(index)
        return YamlValue(ptr)

    def _get_map_item(self, key: str) -> "YamlValue":
        encoded = key.encode("utf-8")
        ptr = _get_lib().zyaml_mapping_get(self._ptr, encoded, len(encoded))
        if not ptr:
            raise KeyError(key)
        return YamlValue(ptr)

    def __contains__(self, key: Union[int, str]) -> bool:
        if isinstance(key, str):
            encoded = key.encode("utf-8")
            return bool(_get_lib().zyaml_mapping_get_borrow(self._ptr, encoded, len(encoded)))
        if isinstance(key, int):
            return 0 <= key < len(self)
        return False

    def __iter__(self) -> Iterator:
        if self.type == YamlType.SEQUENCE:
            return (self[i] for i in range(len(self)))
        if self.type == YamlType.MAPPING:
            return (self[k] for k in self.keys())
        return iter([])

    def keys(self) -> list[str]:
        if self.type != YamlType.MAPPING:
            return []
        return _mapping_keys(self._ptr)

    def values(self) -> list["YamlValue"]:
        return [self[k] for k in self.keys()]

    def items(self) -> list[tuple[str, "YamlValue"]]:
        return [(k, self[k]) for k in self.keys()]

    def get(self, key: str, default: Any = None) -> Any:
        try:
            return self[key]
        except KeyError:
            return default

    def stringify(self) -> str:
        return _read_cstr(_get_lib().zyaml_stringify(self._ptr))

    def __repr__(self) -> str:
        t = self.type
        if t == YamlType.NULL:
            return "YamlValue(null)"
        if t == YamlType.BOOLEAN:
            return f"YamlValue(bool={_get_lib().zyaml_as_bool(self._ptr)})"
        if t == YamlType.INTEGER:
            return f"YamlValue(int={_get_lib().zyaml_as_integer(self._ptr)})"
        if t == YamlType.FLOAT:
            return f"YamlValue(float={_get_lib().zyaml_as_float(self._ptr)})"
        if t == YamlType.STRING:
            return f"YamlValue(string={_read_cstr(_get_lib().zyaml_as_string(self._ptr))!r})"
        if t == YamlType.SEQUENCE:
            return f"YamlValue(sequence, len={len(self)})"
        if t == YamlType.MAPPING:
            return f"YamlValue(mapping, len={len(self)})"
        return "YamlValue(unknown)"

    def __str__(self) -> str:
        return self.stringify()

    def __eq__(self, other: object) -> bool:
        return self.to_python() == other

    def __bool__(self) -> bool:
        return self.type != YamlType.NULL


def _mapping_keys(ptr: int) -> list[str]:
    n = _get_lib().zyaml_mapping_len(ptr)
    out_len = ctypes.c_size_t(0)
    result: list[str] = []
    for i in range(n):
        kp = _get_lib().zyaml_mapping_get_key_borrow(ptr, i, ctypes.byref(out_len))
        result.append(_read_borrowed(kp, out_len.value))
    return result


def _raise_parse_error() -> None:
    raw = _get_lib().zyaml_error_message()
    msg = _read_cstr(raw) if raw else "unknown parse error"
    raise YAMLError(msg)


def parse(input: str) -> YamlValue:
    encoded = input.encode("utf-8")
    ptr = _get_lib().zyaml_parse(encoded, len(encoded))
    if not ptr:
        _raise_parse_error()
    return YamlValue(ptr)


def parse_file(path: str) -> YamlValue:
    ptr = _get_lib().zyaml_parse_file(path.encode("utf-8"))
    if not ptr:
        _raise_parse_error()
    return YamlValue(ptr)
