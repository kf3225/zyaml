# YAML 1.2.2 Specification Summary

**Version:** 1.2.2 (2021-10-01)
**Source:** https://yaml.org/spec/1.2.2/

## Overview

YAML (YAML Ain't Markup Language) is a human-friendly data serialization language designed around common native data types of dynamic programming languages.

## Design Goals (Priority Order)

1. Easily readable by humans
2. Portable between programming languages
3. Match native data structures of dynamic languages
4. Consistent model for generic tools
5. Support one-pass processing
6. Expressive and extensible
7. Easy to implement and use

## Information Models

### 1. Representation Graph

A rooted, connected, directed graph of tagged nodes.

**Node Kinds:**
- **Scalar**: Opaque datum presentable as Unicode characters
- **Sequence**: Ordered series of zero or more nodes
- **Mapping**: Unordered set of key/value pairs (keys must be unique)

**Tags:**
- Global tags: URIs (e.g., `tag:yaml.org,2002:int`)
- Local tags: Start with `!`, application-specific

**Node Comparison:**
- Two nodes are equal if they have the same tag and content
- Scalars: canonical form character-by-character comparison
- Collections: recursive equality

### 2. Serialization Tree

Ordered tree representation for sequential access.

**Serialization Details:**
- Mapping key order (imposed for serialization)
- Anchors (`&name`) and Aliases (`*name`) for node references

### 3. Presentation Stream

Unicode character stream with human-readable formatting.

**Presentation Details:**
- Node styles (block/flow)
- Scalar formats
- Comments
- Directives
- Indentation

## Processing Stages

### Dump (Native → Stream)

1. **Represent**: Native data structures → Representation graph
2. **Serialize**: Representation graph → Serialization tree
3. **Present**: Serialization tree → Character stream

### Load (Stream → Native)

1. **Parse**: Character stream → Serialization tree
2. **Compose**: Serialization tree → Representation graph
3. **Construct**: Representation graph → Native data structures

## Character Productions (Chapter 5)

### Character Set

- Printable Unicode characters
- UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE encodings

### Indicator Characters

| Character | Name | Usage |
|-----------|------|-------|
| `-` | Hyphen | Block sequence entry |
| `:` | Colon | Key/value separator |
| `{` `}` | Curly braces | Flow mapping |
| `[` `]` | Square brackets | Flow sequence |
| `,` | Comma | Flow collection separator |
| `#` | Octothorpe | Comment start |
| `&` | Ampersand | Anchor |
| `*` | Asterisk | Alias |
| `!` | Exclamation | Tag |
| `\|` | Pipe | Literal block scalar |
| `>` | Greater | Folded block scalar |
| `'` | Single quote | Single-quoted scalar |
| `"` | Double quote | Double-quoted scalar |
| `%` | Percent | Directive |
| `?` | Question | Mapping key |
| `---` | Document start | Document marker |
| `...` | Document end | Document marker |

### Line Break Characters

- CR, LF, CRLF normalized to LF

### White Space

- Space (U+0020)
- Tab (U+0009) - NOT allowed for indentation

### Escape Sequences (Double-quoted)

| Escape | Character |
|--------|-----------|
| `\0` | Null (U+0000) |
| `\a` | Bell (U+0007) |
| `\b` | Backspace (U+0008) |
| `\t` | Tab (U+0009) |
| `\n` | Line feed (U+000A) |
| `\v` | Vertical tab (U+000B) |
| `\f` | Form feed (U+000C) |
| `\r` | Carriage return (U+000D) |
| `\e` | Escape (U+001B) |
| `\ ` | Space (U+0020) |
| `\"` | Double quote |
| `\/` | Slash |
| `\\` | Backslash |
| `\N` | Next line (U+0085) |
| `\_` | Non-breaking space (U+00A0) |
| `\L` | Line separator (U+2028) |
| `\P` | Paragraph separator (U+2029) |
| `\xHH` | 2-digit hex |
| `\uHHHH` | 4-digit hex |
| `\UHHHHHHHH` | 8-digit hex |

## Structural Productions (Chapter 6)

### Indentation Spaces

- Must be spaces (NOT tabs)
- Consistent within a block
- Determines block structure

### Separation Spaces

- Separate node properties from content
- Inside flow collections

### Line Folding

- In flow scalars, line breaks folded to spaces
- In block scalars, controlled by indicator

### Comments

- Start with `#`
- Continue to end of line
- Must not appear inside scalars
- Are presentation details (ignored in representation)

### Directives

**YAML Directive:**
```yaml
%YAML 1.2
```

**TAG Directive:**
```yaml
%TAG ! tag:example.com,2024:
```

### Node Properties

- **Tag**: `!tag` or `!!str` or `!<uri>`
- **Anchor**: `&name`

## Flow Style Productions (Chapter 7)

### Alias Nodes

```yaml
- &anchor value
- *anchor  # reference to above
```

### Empty Nodes

```yaml
a:        # empty value (null)
b: ""     # empty string
```

### Flow Scalar Styles

**Plain Style:**
```yaml
key: plain value
```

**Single-Quoted Style:**
```yaml
key: 'value with ''escaped'' quotes'
```

**Double-Quoted Style:**
```yaml
key: "value with \"escaped\" quotes and \n newlines"
```

### Flow Collections

**Flow Sequence:**
```yaml
[a, b, c]
```

**Flow Mapping:**
```yaml
{key1: value1, key2: value2}
```

## Block Style Productions (Chapter 8)

### Block Scalar Headers

**Indentation Indicator:**
```yaml
|2
    indented content
```

**Chomping Indicator:**
- `-` (clip): Single newline at end (default)
- `+` (keep): Preserve all trailing newlines
- (none): Strip trailing newlines

### Literal Style (`|`)

Preserves all newlines:
```yaml
|
  line1
  line2
```
Result: `"line1\nline2\n"`

### Folded Style (`>`)

Folds newlines to spaces:
```yaml
>
  line1
  line2
```
Result: `"line1 line2\n"`

**Exceptions (preserved):**
- Blank lines
- More-indented lines

### Block Sequences

```yaml
- item1
- item2
-
  nested1
  nested2
```

### Block Mappings

```yaml
key1: value1
key2:
  nested: value2
```

## Document Stream Productions (Chapter 9)

### Document Markers

- `---` - Document start
- `...` - Document end

### Document Types

**Bare Document:**
```yaml
scalar
```

**Explicit Document:**
```yaml
---
scalar
...
```

**Directives Document:**
```yaml
%YAML 1.2
%TAG ! tag:example.com:
---
content
```

### Streams

Multiple documents in one stream:
```yaml
---
doc1
---
doc2
```

## Recommended Schemas (Chapter 10)

### Failsafe Schema

**Tags:**
- `tag:yaml.org,2002:map` - Generic mapping
- `tag:yaml.org,2002:seq` - Generic sequence
- `tag:yaml.org,2002:str` - Generic string

### JSON Schema

Adds:
- `tag:yaml.org,2002:null` - `~`, `null`, `Null`, `NULL`
- `tag:yaml.org,2002:bool` - `true`, `false` (case-insensitive)
- `tag:yaml.org,2002:int` - Integer representations
- `tag:yaml.org,2002:float` - Float representations

### Core Schema

Extends JSON Schema with:
- Octal integers: `0o14`
- Hex integers: `0xC`
- Float: `.inf`, `-.inf`, `.nan`
- Timestamps (optional)

## Tag Resolution

| Pattern | Tag |
|---------|-----|
| `null`, `Null`, `NULL`, `~`, empty | `tag:yaml.org,2002:null` |
| `true`, `True`, `TRUE` | `tag:yaml.org,2002:bool` |
| `false`, `False`, `FALSE` | `tag:yaml.org,2002:bool` |
| Integer patterns | `tag:yaml.org,2002:int` |
| Float patterns | `tag:yaml.org,2002:float` |
| Everything else | `tag:yaml.org,2002:str` |

## Loading Failure Points

1. **Ill-formed streams** - Syntax errors
2. **Unidentified aliases** - Reference to unknown anchor
3. **Unresolved tags** - Cannot determine tag
4. **Unrecognized tags** - Tag not known to processor
5. **Invalid content** - Content doesn't match tag constraints
6. **Unavailable tags** - Native type not available

## Key Constraints

- Mapping keys must be unique (equality comparison)
- Tab characters cannot be used for indentation
- Indentation must be consistent within each block
- Flow collections must be properly closed
- Escape sequences must be valid in double-quoted strings
