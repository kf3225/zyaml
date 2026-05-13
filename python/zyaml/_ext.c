#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __linux__
__attribute__((visibility("default"))) void __zig_probe_stack(uintptr_t stack) {
    volatile char *p = (volatile char *)stack;
    *p;
}
#endif

typedef enum {
    ZYAML_NULL = 0, ZYAML_BOOLEAN = 1, ZYAML_INTEGER = 2, ZYAML_FLOAT = 3,
    ZYAML_STRING = 4, ZYAML_SEQUENCE = 5, ZYAML_MAPPING = 6,
} ZyamlType;

typedef void ZyamlValue;

extern ZyamlValue *zyaml_parse(const char *input, size_t len);
extern void zyaml_free(ZyamlValue *value);
extern int zyaml_type(ZyamlValue *value);
extern bool zyaml_as_bool(ZyamlValue *value);
extern int64_t zyaml_as_integer(ZyamlValue *value);
extern double zyaml_as_float(ZyamlValue *value);
extern const char *zyaml_as_string_borrow(ZyamlValue *value, size_t *out_len);
extern size_t zyaml_sequence_len(ZyamlValue *value);
extern ZyamlValue *zyaml_sequence_get_borrow(ZyamlValue *value, size_t index);
extern size_t zyaml_mapping_len(ZyamlValue *value);
extern const char *zyaml_mapping_get_key_borrow(ZyamlValue *value, size_t index, size_t *out_len);
extern ZyamlValue *zyaml_mapping_get_borrow(ZyamlValue *value, const char *key, size_t key_len);
extern ZyamlValue *zyaml_value_null(void);
extern ZyamlValue *zyaml_value_bool(bool b);
extern ZyamlValue *zyaml_value_int(int64_t i);
extern ZyamlValue *zyaml_value_float(double f);
extern ZyamlValue *zyaml_value_string(const char *s, size_t len);
extern ZyamlValue *zyaml_value_sequence(void);
extern bool zyaml_value_sequence_append(ZyamlValue *seq, ZyamlValue *val);
extern ZyamlValue *zyaml_value_mapping(void);
extern bool zyaml_value_mapping_put(ZyamlValue *map, const char *key, size_t key_len, ZyamlValue *val);
extern char *zyaml_stringify_options(ZyamlValue *value, int indent, bool sort_keys, int flow, size_t *out_len);
extern ZyamlValue *zyaml_mapping_get_value_borrow(ZyamlValue *value, size_t index);
extern void zyaml_free_cstr(char *s);

/* ---- load: Value -> Python ---- */

static PyObject *value_to_py(ZyamlValue *v) {
    if (!v) Py_RETURN_NONE;
    switch (zyaml_type(v)) {
    case ZYAML_NULL: Py_RETURN_NONE;
    case ZYAML_BOOLEAN: return Py_NewRef(zyaml_as_bool(v) ? Py_True : Py_False);
    case ZYAML_INTEGER: return PyLong_FromLongLong(zyaml_as_integer(v));
    case ZYAML_FLOAT: return PyFloat_FromDouble(zyaml_as_float(v));
    case ZYAML_STRING: {
        size_t slen = 0;
        const char *s = zyaml_as_string_borrow(v, &slen);
        return PyUnicode_FromStringAndSize(s ? s : "", slen);
    }
    case ZYAML_SEQUENCE: {
        size_t n = zyaml_sequence_len(v);
        PyObject *list = PyList_New(n);
        if (!list) return NULL;
        for (size_t i = 0; i < n; i++) {
            PyObject *item = value_to_py(zyaml_sequence_get_borrow(v, i));
            if (!item) { Py_DECREF(list); return NULL; }
            PyList_SET_ITEM(list, i, item);
        }
        return list;
    }
    case ZYAML_MAPPING: {
        size_t n = zyaml_mapping_len(v);
        PyObject *dict = PyDict_New();
        if (!dict) return NULL;
        for (size_t i = 0; i < n; i++) {
            size_t klen = 0;
            const char *kptr = zyaml_mapping_get_key_borrow(v, i, &klen);
            PyObject *key = PyUnicode_FromStringAndSize(kptr, klen);
            if (!key) { Py_DECREF(dict); return NULL; }
            PyObject *val = value_to_py(zyaml_mapping_get_value_borrow(v, i));
            if (!val) { Py_DECREF(key); Py_DECREF(dict); return NULL; }
            if (PyDict_SetItem(dict, key, val) < 0) {
                Py_DECREF(key);
                Py_DECREF(val);
                Py_DECREF(dict);
                return NULL;
            }
            Py_DECREF(key);
            Py_DECREF(val);
        }
        return dict;
    }
    }
    Py_RETURN_NONE;
}

/* ---- dump: Python -> Value ---- */

static int is_scalar(PyObject *obj) {
    return obj == Py_None || PyBool_Check(obj) || PyLong_Check(obj) ||
           PyFloat_Check(obj) || PyUnicode_Check(obj);
}

static ZyamlValue *py_to_value(PyObject *obj) {
    if (obj == Py_None) return zyaml_value_null();
    if (PyBool_Check(obj)) return zyaml_value_bool(obj == Py_True);
    if (PyLong_Check(obj)) {
        int overflow = 0;
        long long v = PyLong_AsLongLongAndOverflow(obj, &overflow);
        if (overflow) {
            double d = PyLong_AsDouble(obj);
            if (d == -1.0 && PyErr_Occurred()) return NULL;
            return zyaml_value_float(d);
        }
        return zyaml_value_int((int64_t)v);
    }
    if (PyFloat_Check(obj)) return zyaml_value_float(PyFloat_AsDouble(obj));
    if (PyUnicode_Check(obj)) {
        Py_ssize_t len = 0;
        const char *s = PyUnicode_AsUTF8AndSize(obj, &len);
        if (!s) return NULL;
        return zyaml_value_string(s, (size_t)len);
    }
    if (PyList_Check(obj)) {
        ZyamlValue *seq = zyaml_value_sequence();
        if (!seq) return NULL;
        Py_ssize_t n = PyList_GET_SIZE(obj);
        for (Py_ssize_t i = 0; i < n; i++) {
            ZyamlValue *item = py_to_value(PyList_GET_ITEM(obj, i));
            if (!item) { zyaml_free(seq); return NULL; }
            if (!zyaml_value_sequence_append(seq, item)) {
                zyaml_free(item);
                zyaml_free(seq);
                return NULL;
            }
        }
        return seq;
    }
    if (PyDict_Check(obj)) {
        ZyamlValue *map = zyaml_value_mapping();
        if (!map) return NULL;
        PyObject *key, *val;
        Py_ssize_t pos = 0;
        while (PyDict_Next(obj, &pos, &key, &val)) {
            if (!PyUnicode_Check(key)) continue;
            Py_ssize_t klen = 0;
            const char *kptr = PyUnicode_AsUTF8AndSize(key, &klen);
            if (!kptr) { zyaml_free(map); return NULL; }
            ZyamlValue *vval = py_to_value(val);
            if (!vval) { zyaml_free(map); return NULL; }
            if (!zyaml_value_mapping_put(map, kptr, (size_t)klen, vval)) {
                zyaml_free(vval);
                zyaml_free(map);
                return NULL;
            }
        }
        return map;
    }
    return zyaml_value_null();
}

/* ---- module functions ---- */

static PyObject *ext_load(PyObject *self, PyObject *args) {
    const char *input;
    Py_ssize_t len;
    if (!PyArg_ParseTuple(args, "s#", &input, &len)) return NULL;
    ZyamlValue *v = zyaml_parse(input, (size_t)len);
    if (!v) { PyErr_SetString(PyExc_RuntimeError, "parse error"); return NULL; }
    PyObject *result = value_to_py(v);
    zyaml_free(v);
    return result;
}

static int append_text(PyObject **result, const char *suffix) {
    PyObject *extra = PyUnicode_FromString(suffix);
    if (!extra) return -1;
    PyUnicode_Append(result, extra);
    Py_DECREF(extra);
    return *result ? 0 : -1;
}

static PyObject *ext_dump(PyObject *self, PyObject *args, PyObject *kwargs) {
    PyObject *data;
    int indent = 2;
    int sort_keys = 1;
    int flow = 0;
    static char *kwlist[] = {"data", "indent", "sort_keys", "flow", NULL};
    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "O|iii", kwlist, &data, &indent, &sort_keys, &flow))
        return NULL;
    ZyamlValue *v = py_to_value(data);
    if (!v) { PyErr_SetString(PyExc_RuntimeError, "dump error"); return NULL; }
    size_t out_len = 0;
    char *yaml = zyaml_stringify_options(v, indent, (bool)sort_keys, flow, &out_len);
    zyaml_free(v);
    if (!yaml) { PyErr_SetString(PyExc_RuntimeError, "stringify error"); return NULL; }
    PyObject *result = PyUnicode_FromStringAndSize(yaml, out_len);
    zyaml_free_cstr(yaml);
    if (!result) return NULL;
    /* PyYAML format: scalars get ...\n, collections just \n.
       But quoted strings (those starting with ') do NOT get ...\n */
    if (is_scalar(data)) {
        const char *yaml_str = PyUnicode_AsUTF8(result);
        if (!yaml_str) {
            Py_DECREF(result);
            return NULL;
        }
        if (yaml_str[0] != '\'') {
            if (append_text(&result, "\n...\n") < 0) return NULL;
        } else {
            if (append_text(&result, "\n") < 0) return NULL;
        }
    } else {
        if (append_text(&result, "\n") < 0) return NULL;
    }
    return result;
}

static PyMethodDef methods[] = {
    {"load", ext_load, METH_VARARGS, "Parse YAML string to Python object"},
    {"dump", (PyCFunction)ext_dump, METH_VARARGS | METH_KEYWORDS, "Dump Python object to YAML string"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT, "_ext", NULL, -1, methods
};

PyMODINIT_FUNC PyInit__ext(void) {
    return PyModule_Create(&module);
}
