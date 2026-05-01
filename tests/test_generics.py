"""Tests for zyaml generic typed interface (safe_load with type= parameter)."""

import dataclasses
from typing import Any

import zyaml


# ===================================================================
# Basic type coercion
# ===================================================================


class TestBasicCoercion:
    def test_dict(self):
        r = zyaml.safe_load("a: 1\nb: 2", type=dict)
        assert isinstance(r, dict)
        assert r == {"a": 1, "b": 2}

    def test_list(self):
        r = zyaml.safe_load("[1, 2, 3]", type=list)
        assert isinstance(r, list)
        assert r == [1, 2, 3]

    def test_int(self):
        r = zyaml.safe_load("42", type=int)
        assert isinstance(r, int)
        assert r == 42

    def test_float(self):
        r = zyaml.safe_load("3.14", type=float)
        assert isinstance(r, float)

    def test_str(self):
        r = zyaml.safe_load("hello", type=str)
        assert isinstance(r, str)
        assert r == "hello"

    def test_bool(self):
        r = zyaml.safe_load("true", type=bool)
        assert isinstance(r, bool)
        assert r is True

    def test_none_type_without_type_param(self):
        r = zyaml.safe_load("a: 1")
        assert r == {"a": 1}


# ===================================================================
# Nested generic types
# ===================================================================


class TestNestedGenerics:
    def test_dict_str_int(self):
        r = zyaml.safe_load("a: 1\nb: 2", type=dict[str, int])
        assert r == {"a": 1, "b": 2}

    def test_dict_str_str(self):
        r = zyaml.safe_load("a: hello\nb: world", type=dict[str, str])
        assert r == {"a": "hello", "b": "world"}

    def test_list_int(self):
        r = zyaml.safe_load("[1, 2, 3]", type=list[int])
        assert r == [1, 2, 3]

    def test_list_str(self):
        r = zyaml.safe_load("[a, b, c]", type=list[str])
        assert r == ["a", "b", "c"]

    def test_nested_dict(self):
        r = zyaml.safe_load("db:\n  host: localhost\n  port: 5432", type=dict[str, dict[str, Any]])
        assert r == {"db": {"host": "localhost", "port": 5432}}

    def test_dict_with_list_value(self):
        r = zyaml.safe_load("items:\n  - a\n  - b", type=dict[str, list[str]])
        assert r == {"items": ["a", "b"]}

    def test_list_of_dict(self):
        r = zyaml.safe_load("- name: Alice\n- name: Bob", type=list[dict[str, Any]])
        assert r == [{"name": "Alice"}, {"name": "Bob"}]


# ===================================================================
# Dataclass coercion
# ===================================================================


class TestDataclassCoercion:
    def test_simple_dataclass(self):
        @dataclasses.dataclass
        class Config:
            host: str
            port: int

        r = zyaml.safe_load("host: localhost\nport: 5432", type=Config)
        assert isinstance(r, Config)
        assert r.host == "localhost"
        assert r.port == 5432

    def test_nested_dataclass(self):
        @dataclasses.dataclass
        class Database:
            host: str
            port: int

        @dataclasses.dataclass
        class Config:
            name: str
            database: Database

        r = zyaml.safe_load("name: app\ndatabase:\n  host: localhost\n  port: 5432", type=Config)
        assert isinstance(r, Config)
        assert r.name == "app"
        assert isinstance(r.database, Database)
        assert r.database.host == "localhost"

    def test_dataclass_with_optional(self):
        @dataclasses.dataclass
        class Config:
            name: str
            timeout: int = 30

        r = zyaml.safe_load("name: app", type=Config)
        assert r.name == "app"
        assert r.timeout == 30

    def test_dataclass_with_list(self):
        @dataclasses.dataclass
        class Server:
            hosts: list[str]
            port: int

        r = zyaml.safe_load("hosts:\n  - a\n  - b\nport: 8080", type=Server)
        assert r.hosts == ["a", "b"]
        assert r.port == 8080


# ===================================================================
# Regular class (constructor) coercion
# ===================================================================


class TestClassCoercion:
    def test_class_with_kwargs(self):
        class Point:
            def __init__(self, x: int, y: int):
                self.x = x
                self.y = y

        r = zyaml.safe_load("x: 10\ny: 20", type=Point)
        assert isinstance(r, Point)
        assert r.x == 10
        assert r.y == 20


# ===================================================================
# Type coercion errors
# ===================================================================


class TestCoercionErrors:
    def test_wrong_type_raises(self):
        import pytest

        with pytest.raises(TypeError):
            zyaml.safe_load("[1, 2, 3]", type=dict)

    def test_dict_to_list_raises(self):
        import pytest

        with pytest.raises(TypeError):
            zyaml.safe_load("a: 1", type=list)


# ===================================================================
# load / full_load / unsafe_load with type=
# ===================================================================


class TestTypedLoadVariants:
    def test_load_with_type(self):
        r = zyaml.load("a: 1\nb: 2", Loader=zyaml.SafeLoader, type=dict[str, int])
        assert r == {"a": 1, "b": 2}

    def test_full_load_with_type(self):
        r = zyaml.full_load("x: 42", type=dict[str, int])
        assert r == {"x": 42}

    def test_unsafe_load_with_type(self):
        r = zyaml.unsafe_load("x: hello", type=dict[str, str])
        assert r == {"x": "hello"}
