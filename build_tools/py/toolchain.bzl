_cpython_37_ATTR = "cpython_37"
_cpython_27_ATTR = "cpython_27"
_cpython_37_BUILD_TAG = "cpython-37"
_cpython_27_BUILD_TAG = "cpython-27"

# If you add a new build_tag here also need to update ALL_PYTHON_TAGS in
# build_tools/gen_build_pip.py or bzl gen will not add contexts for its wheels.
cpython_37 = struct(
    build_tag = _cpython_37_BUILD_TAG,
    attr = _cpython_37_ATTR,
)
cpython_27 = struct(
    build_tag = _cpython_27_BUILD_TAG,
    attr = _cpython_27_ATTR,
)

ALL_ABIS = [
    cpython_37,
    cpython_27,
]

CPYTHON_27_TOOLCHAIN_NAME = "@dbx_build_tools//build_tools/py:toolchain_27"
CPYTHON_37_TOOLCHAIN_NAME = "@dbx_build_tools//build_tools/py:toolchain_37"

DEFAULT_PY3_TOOLCHAIN_NAME = CPYTHON_37_TOOLCHAIN_NAME

BUILD_TAG_TO_TOOLCHAIN_MAP = {
    cpython_37.build_tag: CPYTHON_37_TOOLCHAIN_NAME,
    cpython_27.build_tag: CPYTHON_27_TOOLCHAIN_NAME,
    # NOTE: These entries are mainly here for compatibility reasons.
    # Once we migrate over to purely specifying tags for "python" values, these
    # compat entries can be dropped.
    "//thirdparty/cpython:drte-interpreter-37": CPYTHON_37_TOOLCHAIN_NAME,
    "//thirdparty/cpython:drte-interpreter": CPYTHON_27_TOOLCHAIN_NAME,
}

DbxPyInterpreter = provider(fields = [
    "path",
    "runfiles_path",
    "build_tag",
    "headers",
    "runtime",
    "major_python_version",
])

def get_default_py_toolchain_name(python2_compatible):
    if not python2_compatible:
        return DEFAULT_PY3_TOOLCHAIN_NAME
    return CPYTHON_27_TOOLCHAIN_NAME

def get_py_toolchain_name(python_or_build_tag):
    """Gets the top-level toolchain name."""
    toolchain = BUILD_TAG_TO_TOOLCHAIN_MAP[python_or_build_tag]
    return toolchain

def _dbx_py_interpreter_impl(ctx):
    if not (ctx.attr.exe or ctx.attr.exe_file):
        fail("exe or exe_file is mandatory")
    if ctx.attr.exe:
        path = ctx.attr.exe
        runfiles_path = ctx.attr.exe
    else:
        path = ctx.file.exe_file.path
        runfiles_path = "/".join([
            "$RUNFILES",
            ctx.file.exe_file.short_path,
        ])
    return [
        DbxPyInterpreter(
            path = path,
            runfiles_path = runfiles_path,
            build_tag = ctx.attr.build_tag,
            headers = ctx.attr.headers.files if ctx.attr.headers else depset(),
            runtime = ctx.attr.runtime.files if ctx.attr.runtime else depset(),
            major_python_version = ctx.attr.major_python_version,
        ),
    ]

dbx_py_interpreter = rule(
    implementation = _dbx_py_interpreter_impl,
    attrs = {
        "exe": attr.string(),
        "exe_file": attr.label(allow_single_file = True),
        "build_tag": attr.string(mandatory = True),
        "headers": attr.label(),
        "runtime": attr.label(),
        "major_python_version": attr.int(default = 2),
    },
)

def _dbx_py_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            interpreter = ctx.attr.interpreter,
            pyc_compile_exe = ctx.executable.pyc_compile,
            pyc_compile_files_to_run = ctx.attr.pyc_compile[DefaultInfo].files_to_run,
            dbx_importer = ctx.attr.dbx_importer,
        ),
    ]

dbx_py_toolchain = rule(
    _dbx_py_toolchain_impl,
    attrs = {
        "interpreter": attr.label(mandatory = True),
        "pyc_compile": attr.label(mandatory = True, executable = True, cfg = "host"),
        "dbx_importer": attr.label(),
    },
    doc = """
Python toolchain.

The Python toolchain includes a Python interpreter and the tools
needed to build and run Python binaries.

Attributes:

 - interpreter: A dbx_py_interpreter. The interpreter used to build
   and run Python files and libraries.

 - pyc_compile: A dbx_py_internal_bootstrap binary that takes a set of
   files and compiles them to pyc.

 - dbx_importer: Optional. A py_library that's used to import
   Dropbox's custom pyc files.

The toolchain returns the following fields:

 - interpreter: The dbx_py_interpreter for the build_tag.
 - pyc_compile_exe: The executable file for pyc_compile.
 - pyc_compile_files_to_run: The runfiles for pyc_compile.
 - dbx_importer: The importer attribute, or None if it's not passed
   in.

For some reason, executables don't contain the runfiles when you add
them as an executable for a `ctx.actions.run` action. You need to make
sure to include the files_to_run as a tool for the `run` action,
otherwise those files aren't "included" as part of the build (e.g.
they may still be accessible since the script can escape the sandbox,
but changes to the runfiles won't cause a rebuild).

When you use dbx_py_internal_bootstrap binaries attached to the
toolchain, you'll also need to include the dbx_py_interpreter's
runtime as `srcs` and the python binary as `DBX_PYTHON`.

E.g. you always need to do this:

```
python = ctx.toolchains[get_py_toolchain_name(build_tag)].interpreter[DbxPyInterpreter]
ctx.actions.run(
    inputs = srcs + python.runtime.to_list(),
    tools = [toolchain.pyc_compile_files_to_run],
    executable = toolchain.pyc_compile_exe,
    env = {
        "DBX_PYTHON": python.path,
    },
    ...
)
```

    """,
)
