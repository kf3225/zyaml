import io
import os

import zyaml
import pytest


def test_basic_scalars():
    assert zyaml.safe_load("42") == 42
    assert zyaml.safe_load("3.14") == 3.14
    assert zyaml.safe_load("true") is True
    assert zyaml.safe_load("false") is False
    assert zyaml.safe_load("null") is None


def test_parse_scalar():
    doc = zyaml.parse("key: value")
    assert doc["key"].to_python() == "value"


def test_sequence():
    doc = zyaml.parse("[1, 2, 3]")
    assert len(doc) == 3
    assert doc[0].to_python() == 1
    assert doc[1].to_python() == 2
    assert doc[2].to_python() == 3


def test_mapping():
    doc = zyaml.parse("name: Alice\nage: 30\ncity: Tokyo")
    assert len(doc) == 3
    assert doc["name"].to_python() == "Alice"
    assert doc["age"].to_python() == 30
    assert doc["city"].to_python() == "Tokyo"


def test_nested():
    doc = zyaml.parse('person:\n  name: Bob\n  address:\n    city: Osaka\n    zip: "530-0001"')
    assert doc["person"]["name"].to_python() == "Bob"
    assert doc["person"]["address"]["city"].to_python() == "Osaka"
    assert doc["person"]["address"]["zip"].to_python() == "530-0001"


def test_block_sequence():
    doc = zyaml.parse("fruits:\n  - apple\n  - banana\n  - cherry")
    fruits = doc["fruits"]
    assert len(fruits) == 3
    assert fruits[0].to_python() == "apple"
    assert fruits[1].to_python() == "banana"
    assert fruits[2].to_python() == "cherry"


def test_safe_load():
    result = zyaml.safe_load("database:\n  host: localhost\n  port: 5432\n  debug: true")
    assert isinstance(result, dict)
    assert result["database"]["host"] == "localhost"
    assert result["database"]["port"] == 5432
    assert result["database"]["debug"] is True


def test_stringify():
    doc = zyaml.parse("hello: world")
    output = doc.stringify()
    assert "hello" in output
    assert "world" in output


def test_parse_error():
    with pytest.raises(zyaml.YAMLError):
        zyaml.safe_load("\tindented: wrong")


def test_duplicate_flow_key_error():
    with pytest.raises(zyaml.YAMLError):
        zyaml.safe_load("{a: 1, a: 2}")


def test_keys_items():
    doc = zyaml.parse("a: 1\nb: 2\nc: 3")
    keys = doc.keys()
    assert "a" in keys
    assert "b" in keys
    assert "c" in keys
    for k, v in doc.items():
        assert v.to_python() in (1, 2, 3)


def test_repr():
    doc = zyaml.parse("42")
    assert "int=42" in repr(doc)
    doc2 = zyaml.parse("hello")
    assert "string=" in repr(doc2)


def test_parse_file():
    path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "src",
        "test",
        "fixtures",
        "01_scalars.yaml",
    )
    if not os.path.exists(path):
        pytest.skip("fixtures not found")
    doc = zyaml.parse_file(path)
    assert doc.type == zyaml.YamlType.MAPPING
    assert doc["string_value"].to_python() == "hello world"
    assert doc["integer_value"].to_python() == 42
    assert doc["boolean_true"].to_python() is True


def test_contains():
    doc = zyaml.parse("a: 1\nb: 2")
    assert "a" in doc
    assert "c" not in doc


def test_roundtrip():
    doc = zyaml.parse("name: test\nvalue: 42")
    output = doc.stringify()
    doc2 = zyaml.parse(output)
    assert doc2["name"].to_python() == "test"
    assert doc2["value"].to_python() == 42


def test_safe_load_bytes():
    r = zyaml.safe_load(b"a: 1\nb: 2")
    assert r == {"a": 1, "b": 2}


def test_safe_load_file_like():
    r = zyaml.safe_load(io.StringIO("a: 1\nb: 2"))
    assert r == {"a": 1, "b": 2}


def test_safe_load_none():
    r = zyaml.safe_load("")
    assert r is None
