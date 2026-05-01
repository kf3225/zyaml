"""PyYAML-compatible interface tests — zyaml output compared against PyYAML."""

import io

import pytest
import yaml as pyyaml

import zyaml

# ===================================================================
# safe_load — parse YAML string/bytes/file → Python object
# ===================================================================


class TestSafeLoad:
    def test_mapping(self):
        s = "a: 1\nb: 2\nc: 3"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_sequence(self):
        s = "[1, 2, 3]"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_nested_mapping(self):
        s = "parent:\n  child:\n    key: value"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_sequence_of_mappings(self):
        s = "- name: Alice\n- name: Bob"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_block_sequence(self):
        s = "items:\n  - a\n  - b\n  - c"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_integer(self):
        for v in ["0", "42", "-1", "100", "0"]:
            assert zyaml.safe_load(v) == pyyaml.safe_load(v)

    def test_float(self):
        for v in ["3.14", "0.0", "-1.5"]:
            assert zyaml.safe_load(v) == pyyaml.safe_load(v)
        assert isinstance(zyaml.safe_load("1e10"), float)

    def test_boolean(self):
        for v in ["true", "false", "True", "False"]:
            assert zyaml.safe_load(v) == pyyaml.safe_load(v)

    def test_null(self):
        for v in ["null", "Null", "NULL", "~"]:
            assert zyaml.safe_load(v) == pyyaml.safe_load(v)

    def test_string(self):
        s = '"hello world"'
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_string_unquoted(self):
        s = "hello"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_empty_string(self):
        assert zyaml.safe_load("") is None

    def test_bytes_input(self):
        b = b"a: 1\nb: 2"
        assert zyaml.safe_load(b) == pyyaml.safe_load(b)

    def test_file_like_input(self):
        data = "a: 1\nb: 2"
        assert zyaml.safe_load(io.StringIO(data)) == pyyaml.safe_load(io.StringIO(data))

    def test_bytes_io_input(self):
        data = b"a: 1\nb: 2"
        assert zyaml.safe_load(io.BytesIO(data)) == pyyaml.safe_load(io.BytesIO(data))

    def test_flow_mapping(self):
        s = "{a: 1, b: 2, c: 3}"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_nested_flow(self):
        s = "config: {db: {host: localhost, port: 5432}}"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_multiline_string(self):
        s = "key: |\n  line1\n  line2\n"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_folded_string(self):
        s = "key: >\n  line1\n  line2\n"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_quoted_string_with_special(self):
        s = '"hello: world"'
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_hex_integer(self):
        s = "0xFF"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)

    def test_octal_integer(self):
        assert zyaml.safe_load("0o77") == 63

    def test_binary_integer(self):
        s = "0b1010"
        assert zyaml.safe_load(s) == pyyaml.safe_load(s)


# ===================================================================
# safe_dump — Python object → YAML string
# ===================================================================


class TestSafeDump:
    def test_simple_mapping(self):
        data = {"a": 1, "b": 2}
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_sequence(self):
        data = [1, 2, 3]
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_nested(self):
        data = {"parent": {"child": {"key": "value"}}}
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_list_of_dicts(self):
        data = [{"name": "Alice"}, {"name": "Bob"}]
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_none(self):
        z = zyaml.safe_dump(None)
        p = pyyaml.safe_dump(None)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_empty_dict(self):
        z = zyaml.safe_dump({})
        p = pyyaml.safe_dump({})
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_empty_list(self):
        z = zyaml.safe_dump([])
        p = pyyaml.safe_dump([])
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_booleans(self):
        data = {"a": True, "b": False}
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_float(self):
        data = {"pi": 3.14}
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_string_needs_quoting(self):
        data = {"key": "true"}
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_string_with_colon(self):
        data = {"url": "http://example.com"}
        z = zyaml.safe_dump(data)
        p = pyyaml.safe_dump(data)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_sort_keys_true(self):
        data = {"b": 2, "a": 1, "c": 3}
        z = zyaml.safe_dump(data, sort_keys=True)
        p = pyyaml.safe_dump(data, sort_keys=True)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_sort_keys_false(self):
        data = {"b": 2, "a": 1}
        z = zyaml.safe_dump(data, sort_keys=False)
        assert zyaml.safe_load(z) == data

    def test_explicit_start(self):
        data = {"a": 1}
        z = zyaml.safe_dump(data, explicit_start=True)
        assert z.startswith("---")
        assert zyaml.safe_load(z) == data

    def test_default_flow_style_true(self):
        data = {"a": [1, 2]}
        z = zyaml.safe_dump(data, default_flow_style=True)
        p = pyyaml.safe_dump(data, default_flow_style=True)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_default_flow_style_false(self):
        data = {"a": [1, 2]}
        z = zyaml.safe_dump(data, default_flow_style=False)
        p = pyyaml.safe_dump(data, default_flow_style=False)
        assert zyaml.safe_load(z) == pyyaml.safe_load(p)

    def test_indent(self):
        data = {"a": {"b": 1}}
        z = zyaml.safe_dump(data, indent=4)
        assert zyaml.safe_load(z) == data

    def test_to_stream(self):
        data = {"a": 1}
        buf = io.StringIO()
        result = zyaml.safe_dump(data, buf)
        assert result is None
        assert buf.getvalue()
        assert zyaml.safe_load(buf.getvalue()) == data

    def test_roundtrip(self):
        original = {"name": "Alice", "age": 30, "tags": ["dev", "zig"], "meta": {"active": True}}
        z = zyaml.safe_dump(original)
        assert zyaml.safe_load(z) == original

    def test_nan(self):
        z = zyaml.safe_dump(float("nan"))
        assert ".nan" in z

    def test_inf(self):
        z = zyaml.safe_dump(float("inf"))
        assert ".inf" in z and "-.inf" not in z

    def test_negative_inf(self):
        z = zyaml.safe_dump(float("-inf"))
        assert "-.inf" in z


# ===================================================================
# safe_dump_all / safe_load_all — multi-document support
# ===================================================================


class TestDumpAllLoadAll:
    def test_dump_all(self):
        docs = [{"a": 1}, {"b": 2}]
        z = zyaml.safe_dump_all(docs)
        p = pyyaml.safe_dump_all(docs)
        assert list(zyaml.safe_load_all(z)) == list(pyyaml.safe_load_all(p))

    def test_dump_all_to_stream(self):
        docs = [{"a": 1}, {"b": 2}]
        buf = io.StringIO()
        result = zyaml.safe_dump_all(docs, buf)
        assert result is None
        assert buf.getvalue()


# ===================================================================
# load — with Loader argument
# ===================================================================


class TestLoadWithLoader:
    def test_load_with_safe_loader(self):
        r = zyaml.load("a: 1", Loader=zyaml.SafeLoader)
        assert r == {"a": 1}

    def test_load_without_loader_raises(self):
        with pytest.raises(TypeError):
            zyaml.load("a: 1")

    def test_load_all_with_safe_loader(self):
        r = list(zyaml.load_all("---\na: 1\n---\nb: 2", Loader=zyaml.SafeLoader))
        assert r == [{"a": 1}, {"b": 2}]

    def test_load_all_without_loader_raises(self):
        with pytest.raises(TypeError):
            zyaml.load_all("---\na: 1")


# ===================================================================
# full_load / unsafe_load — aliases for safe_load
# ===================================================================


class TestLoadVariants:
    def test_full_load(self):
        assert zyaml.full_load("a: 1") == {"a": 1}

    def test_unsafe_load(self):
        assert zyaml.unsafe_load("a: 1") == {"a": 1}

    def test_full_load_all(self):
        assert list(zyaml.full_load_all("---\na: 1\n---\nb: 2")) == [{"a": 1}, {"b": 2}]

    def test_unsafe_load_all(self):
        assert list(zyaml.unsafe_load_all("---\na: 1\n---\nb: 2")) == [{"a": 1}, {"b": 2}]


# ===================================================================
# dump — with Dumper argument
# ===================================================================


class TestDumpWithDumper:
    def test_dump_default_dumper(self):
        r = zyaml.dump({"a": 1})
        assert r is not None
        assert zyaml.safe_load(r) == {"a": 1}

    def test_dump_with_stream(self):
        buf = io.StringIO()
        zyaml.dump({"a": 1}, buf)
        assert buf.getvalue()

    def test_dump_all_default_dumper(self):
        r = zyaml.dump_all([{"a": 1}, {"b": 2}])
        assert r is not None


# ===================================================================
# Error classes — PyYAML-compatible hierarchy
# ===================================================================


class TestErrors:
    def test_yaml_error_is_exception(self):
        assert issubclass(zyaml.YAMLError, Exception)

    def test_marked_yaml_error_is_yaml_error(self):
        assert issubclass(zyaml.MarkedYAMLError, zyaml.YAMLError)

    def test_parse_error_type(self):
        with pytest.raises(zyaml.YAMLError):
            zyaml.safe_load("\tindented: wrong")

    def test_marked_error_message(self):
        e = zyaml.MarkedYAMLError(problem="test problem")
        assert "test problem" in str(e)


# ===================================================================
# Loader / Dumper stubs — importable
# ===================================================================


class TestStubs:
    def test_safe_loader_importable(self):
        assert zyaml.SafeLoader is not None

    def test_full_loader_importable(self):
        assert zyaml.FullLoader is not None

    def test_unsafe_loader_importable(self):
        assert zyaml.UnsafeLoader is not None

    def test_loader_importable(self):
        assert zyaml.Loader is not None

    def test_base_loader_importable(self):
        assert zyaml.BaseLoader is not None

    def test_safe_dumper_importable(self):
        assert zyaml.SafeDumper is not None

    def test_dumper_importable(self):
        assert zyaml.Dumper is not None

    def test_base_dumper_importable(self):
        assert zyaml.BaseDumper is not None

    def test_safe_loader_constructible(self):
        loader = zyaml.SafeLoader("a: 1")
        assert loader.stream == "a: 1"

    def test_safe_dumper_constructible(self):
        dumper = zyaml.SafeDumper(None, sort_keys=False)
        assert dumper.sort_keys is False


# ===================================================================
# No-op stubs — add_constructor, add_representer, etc.
# ===================================================================


class TestNoOpStubs:
    def test_add_constructor(self):
        zyaml.add_constructor("tag:yaml.org,2002:str", lambda *a: None)

    def test_add_representer(self):
        zyaml.add_representer(str, lambda *a: None)

    def test_add_multi_constructor(self):
        zyaml.add_multi_constructor("!", lambda *a: None)

    def test_add_multi_representer(self):
        zyaml.add_multi_representer(str, lambda *a: None)

    def test_add_implicit_resolver(self):
        zyaml.add_implicit_resolver("tag:yaml.org,2002:str", None)

    def test_add_path_resolver(self):
        zyaml.add_path_resolver("tag:yaml.org,2002:str", None)


# ===================================================================
# Mark class
# ===================================================================


class TestMark:
    def test_mark_str(self):
        m = zyaml.Mark("test.yaml", 0, 5, 10)
        s = str(m)
        assert "line 6" in s
        assert "column 11" in s

    def test_mark_get_snippet(self):
        m = zyaml.Mark("test.yaml", 0, 0, 0)
        assert m.get_snippet() is None
