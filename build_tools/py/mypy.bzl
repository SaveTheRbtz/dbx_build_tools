"""Aspect for running mypy.

This defines a new rule for defining test targets, dbx_mypy_test.
Usage example:

    dbx_mypy_test(
        name = 'foo_mypy',
        deps = ['foo'],
    )

Running the test completes immediately; but building it runs mypy over
all its (transitive) dependencies (which must be dbx_py_library,
dbx_py_binary or dbx_py_test targets).  If mypy complains about any
file in any dependency the test can't be built.

Most of the work is done through aspects; docs are at:
https://docs.bazel.build/versions/master/skylark/aspects.html
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")
load(
    "//build_tools/py:py.bzl",
    "dbx_py_binary_attrs",
    "dbx_py_binary_base_impl",
    "dbx_py_pytest_test",
    "dbx_py_test_attrs",
    "extract_pytest_args",
)
load("//build_tools/py:common.bzl", "DbxPyVersionCompatibility")
load("//build_tools/bazel:quarantine.bzl", "process_quarantine_attr")
load("//build_tools/services:svc.bzl", "dbx_services_test")
load("@dbx_build_tools//build_tools/py:toolchain.bzl", "CPYTHON_37_TOOLCHAIN_NAME")

MypyProvider = provider(fields = [
    "trans_srcs",
    "trans_roots",
    "trans_outs",
    "trans_cache_map",
    "trans_junits",
    # mypyc stuff
    "trans_group",
    "trans_ext_modules",
    "compilation_context",
])

_null_result = MypyProvider(
    trans_outs = depset(),
    trans_srcs = depset(),
    trans_roots = depset(),
    trans_cache_map = depset(),
    trans_junits = depset(),
    trans_group = depset(),
    trans_ext_modules = depset(),
    compilation_context = None,
)

def _get_stub_roots(stub_srcs):
    """
    Helper to add extra roots for stub files in typeshed.

    Paths are of the form:
      <prefix>/{stdlib,third_party}/<version>/<path>
    where:
      <prefix> is external/org_python_typeshed
      <version> can be 2, 3, 2and3, 2.7, 3.3, 3.4 etc.
      <path> is the actual filename we care about, e.g. sys.pyi
    """
    roots = []
    for src in stub_srcs:
        parts = src.path.split("/")
        prefix = []
        for part in parts:
            prefix.append(part)
            if part and part[0].isdigit():
                roots.append("/".join(prefix))
                break
    return roots

def _get_trans_roots(target, srcs, stub_srcs, deps):
    direct = [src.root.path for src in srcs]
    if not target:
        direct += _get_stub_roots(stub_srcs)
    transitive = [
        dep[MypyProvider].trans_roots
        for dep in deps
    ]
    if target:
        transitive.append(target.extra_pythonpath)
    return depset(direct = direct, transitive = transitive)

def _get_trans_outs(outs, deps):
    return depset(
        direct = outs,
        transitive = [dep[MypyProvider].trans_outs for dep in deps],
    )

def _get_trans_srcs(srcs, deps):
    return depset(
        direct = srcs,
        transitive = [dep[MypyProvider].trans_srcs for dep in deps],
    )

def _get_trans_cache_map(cache_map, deps):
    return depset(
        direct = cache_map,
        transitive = [dep[MypyProvider].trans_cache_map for dep in deps],
    )

def _get_trans_group(group, deps):
    return depset(
        direct = group,
        transitive = [dep[MypyProvider].trans_group for dep in deps],
    )

def _get_trans_ext_modules(ext_modules, deps):
    return depset(
        direct = ext_modules,
        transitive = [dep[MypyProvider].trans_ext_modules for dep in deps],
    )

def _format_group(group):
    srcs, name = group
    return "%s:%s" % (name, ",".join([src.path for src in srcs]))

# Rules into which we descend.  Other rules are ignored.  Edit to taste.
_supported_rules = [
    "dbx_mypy_bootstrap",
    "dbx_py_library",
    "dbx_py_binary",
    "dbx_py_compiled_binary",
    "dbx_py_test",
    "services_internal_test",
]

def _dbx_mypy_common_code(target, ctx, deps, srcs, stub_srcs, python_version, use_mypyc):
    """
    Code shared between aspect and bootstrap rule.

    target: rule name for aspect, None for bootstrap
    ctx: original context
    deps, srcs, stub_srcs: rule attributes
    python_version: '2.7' or '3.7'
    """
    if python_version == "2.7":
        use_mypyc = False

    pyver_dash = python_version.replace(".", "-")
    pyver_under = python_version.replace(".", "_")

    # Except for the bootstrap rule, add typeshed to the dependencies.
    if target:
        typeshed = getattr(ctx.attr, "_typeshed_" + pyver_under)
        deps = deps + [typeshed]

    trans_roots = _get_trans_roots(target, srcs, stub_srcs, deps)

    trans_caches = _get_trans_outs([], deps)

    # Merge srcs and stub_srcs -- when foo.py and foo.pyi are both present,
    # only keep the latter.
    stub_paths = {stub.path: None for stub in stub_srcs}  # Used as a set
    srcs = [src for src in srcs if src.path + "i" not in stub_paths] + stub_srcs

    trans_srcs = _get_trans_srcs(srcs, deps)
    if not trans_srcs:
        return [_null_result]

    outs = []
    junit_xml = "%s-%s-junit.xml" % (ctx.label.name.replace("/", "-"), pyver_dash)
    junit_xml_file = ctx.actions.declare_file(junit_xml)
    cache_map = []  # Items for cache_map file.

    ext_modules = []
    compilation_contexts = [
        dep[MypyProvider].compilation_context
        for dep in deps
        if dep[MypyProvider].compilation_context
    ]
    if use_mypyc:
        # If we are using mypyc, mypy will generate C source as part of its output.
        # Create a C extension module using that source.
        shim_template = ctx.attr._module_shim_template[DefaultInfo].files.to_list()[0]
        group_name = str(target.label).lstrip("/").replace("/", ".").replace(":", ".")
        group_libname = group_name + "__mypyc"
        short_name = group_name.split(".")[-1]

        group_files = [
            ctx.actions.declare_file(template % short_name)
            for template in ["__native_internal_%s.h", "__native_%s.h", "__native_%s.c"]
        ]
        outs.extend(group_files)

        internal_header, external_header, group_src = group_files
        ext_module, compilation_context = _build_mypyc_ext_module(
            ctx,
            short_name + "__mypyc",
            group_src,
            [external_header],
            [internal_header],
            compilation_contexts,
        )
        ext_modules.append(ext_module)

        group = (srcs, group_name)
    else:
        # If we aren't using mypyc, we still need to create a
        # compilation context that merges our deps' contexts.
        compilation_context = _merge_compilation_contexts(compilation_contexts)
        group = None

    for src in srcs:
        cache_map.append(src)
        path = src.path
        path_base = path[:path.rindex(".")]  # Strip .py or .pyi suffix
        kinds = ["meta", "data"] + (["ir"] if use_mypyc else [])
        for kind in kinds:
            path = "%s.%s.%s.json" % (path_base, python_version, kind)
            file = ctx.actions.declare_file(path)

            outs.append(file)
            if kind != "ir":
                cache_map.append(file)

        # If we are using mypyc, generate a shim extension module for each module
        if use_mypyc:
            full_modname = path_base.replace("/", ".")
            modname = full_modname.split(".")[-1]
            file = ctx.actions.declare_file(modname + ".c")

            ctx.actions.expand_template(
                template = shim_template,
                output = file,
                substitutions = {
                    "{modname}": modname,
                    "{libname}": group_libname,
                    "{full_modname}": _mypyc_exported_name(full_modname),
                },
            )

            ext_modules.append(_build_mypyc_ext_module(ctx, modname, file)[0])

    trans_outs = _get_trans_outs(outs, deps)
    trans_cache_map = _get_trans_cache_map(cache_map, deps)
    trans_group = _get_trans_group([group] if group else [], deps)

    inputs = depset(transitive = [
        trans_srcs,
        trans_caches,
        ctx.attr._edgestore_plugin.files,
        ctx.attr._sqlalchemy_plugin.files,
        ctx.attr._py3safe_plugin.files,
        ctx.attr._mypy_ini.files,
    ])
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    if use_mypyc:
        args.add("--mypyc")
        args.add_joined(trans_group, join_with = ";", map_each = _format_group)
        args.add(junit_xml_file.root.path)

    args.add("--bazel")
    if python_version != "2.7":
        # For some reason, explicitly passing --python-version 2.7 fails.
        args.add("--python-version", python_version)
    args.add_all(trans_roots, before_each = "--package-root")
    args.add("--no-error-summary")
    args.add("--incremental")
    args.add("--junit-xml", junit_xml_file)
    args.add("--cache-map")
    args.add_all(trans_cache_map)
    args.add("--")
    args.add_all(trans_srcs)
    ctx.actions.run(
        executable = ctx.executable._mypy,
        arguments = [args],
        inputs = inputs,
        outputs = outs + [junit_xml_file],
        mnemonic = "mypy",
        progress_message = "Type-checking %s" % ctx.label,
        tools = [],
    )

    return [
        MypyProvider(
            trans_srcs = trans_srcs,
            trans_roots = trans_roots,
            trans_outs = trans_outs,
            trans_cache_map = trans_cache_map,
            trans_junits = depset(
                direct = [junit_xml_file],
                transitive = [dep[MypyProvider].trans_junits for dep in deps],
            ),
            trans_group = trans_group,
            trans_ext_modules = _get_trans_ext_modules(ext_modules, deps),
            compilation_context = compilation_context,
        ),
    ]

def _mypyc_exported_name(fullname):
    return fullname.replace("___", "___3_").replace(".", "___")

def _build_mypyc_ext_module(
        ctx,
        group_name,
        c_source,
        public_hdrs = [],
        private_hdrs = [],
        compilation_contexts = []):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(ctx = ctx, cc_toolchain = cc_toolchain)

    so_name = "%s.cpython-37m-x86_64-linux-gnu.so" % group_name
    so_file = ctx.actions.declare_file(so_name)

    mypyc_runtime = ctx.attr._mypyc_runtime

    compilation_context, compilation_outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [c_source],
        includes = [c_source.root.path],
        public_hdrs = public_hdrs,
        private_hdrs = private_hdrs,
        name = group_name,
        user_compile_flags = [
            "-Wno-unused-function",
            "-Wno-unused-label",
            "-Wno-unreachable-code",
            "-Wno-unused-variable",
            "-Wno-unused-but-set-variable",
        ],
        compilation_contexts = [mypyc_runtime[CcInfo].compilation_context] + compilation_contexts,
    )
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        output_type = "dynamic_library",
        name = so_name,
        linking_contexts = [mypyc_runtime[CcInfo].linking_context],
    )

    # Copy the file into place, since link generates it with "lib" in front
    args = ctx.actions.args()
    args.add(linking_outputs.library_to_link.dynamic_library)
    args.add(so_file)
    ctx.actions.run(
        executable = "cp",
        arguments = [args],
        inputs = [linking_outputs.library_to_link.dynamic_library],
        outputs = [so_file],
        tools = [],
    )

    return so_file, compilation_context

def _merge_compilation_contexts(ctxs):
    return cc_common.merge_cc_infos(
        cc_infos = [CcInfo(compilation_context = ctx) for ctx in ctxs],
    ).compilation_context

# Attributes shared between aspect and bootstrap.

_dbx_mypy_common_attrs = {
    "_mypy": attr.label(
        default = Label("//dropbox/mypy:mypy"),
        allow_files = True,
        executable = True,
        cfg = "host",
    ),
    "_mypy_ini": attr.label(
        default = Label("//:mypy.ini"),
        allow_files = True,
    ),
    # TODO: Move list of plugins to a separate target
    "_edgestore_plugin": attr.label(
        default = Label("//dropbox/mypy:edgestore_plugin.py"),
        allow_files = True,
    ),
    "_sqlalchemy_plugin": attr.label(
        default = Label("//dropbox/mypy:sqlmypy.py"),
        allow_files = True,
    ),
    "_py3safe_plugin": attr.label(
        default = Label("//dropbox/mypy:py3safe.py"),
        allow_files = True,
    ),
}

# Aspect definition.

def _dbx_mypy_aspect_impl(target, ctx):
    rule = ctx.rule
    if rule.kind not in _supported_rules:
        return [_null_result]
    if not hasattr(rule.attr, "deps") and hasattr(rule.attr, "bin"):
        if rule.kind != "services_internal_test":
            fail("Expected rule kind services_internal_test, got %s" % rule.kind)

        # Special case for tests that specify services=...
        return _dbx_mypy_common_code(
            None,
            ctx,
            [rule.attr.bin],
            [],
            [],
            ctx.attr.python_version,
            False,
        )
    return _dbx_mypy_common_code(
        target,
        ctx,
        rule.attr.deps,
        rule.files.srcs,
        rule.files.stub_srcs,
        ctx.attr.python_version,
        use_mypyc = getattr(rule.attr, "compiled", False),
    )

_dbx_mypy_aspect_attrs = {
    "python_version": attr.string(values = ["2.7", "3.7"]),
    "_typeshed_2_7": attr.label(default = Label("//thirdparty/typeshed:typeshed-2.7")),
    "_typeshed_3_7": attr.label(default = Label("//thirdparty/typeshed:typeshed-3.7")),
    "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
    "_mypyc_runtime": attr.label(default = Label("//thirdparty/mypy:mypyc_runtime")),
    "_module_shim_template": attr.label(default = Label("//thirdparty/mypy:module_shim_template")),
}
_dbx_mypy_aspect_attrs.update(_dbx_mypy_common_attrs)

dbx_mypy_aspect = aspect(
    implementation = _dbx_mypy_aspect_impl,
    attr_aspects = ["deps", "bin"],
    attrs = _dbx_mypy_aspect_attrs,
    fragments = ["cpp"],
    provides = [MypyProvider],
)

# Test rule used to trigger mypy via a test target.
# It is actually a macro so we can expand it to one or two
# rule invocations depending on Python version compatibility;
# we also set size = 'small'.

_dbx_mypy_test_attrs = {
    "deps": attr.label_list(aspects = [dbx_mypy_aspect]),
    "python_version": attr.string(),
    "_mypy_test": attr.label(
        default = Label("//dropbox/mypy:mypy_test"),
        allow_files = True,
        executable = True,
        cfg = "host",
    ),
}
_dbx_mypy_test_attrs.update(runfiles_attrs)

_test_template = """
$RUNFILES/{program} --label {label} {files} >$XML_OUTPUT_FILE
"""

def _dbx_mypy_test_impl(ctx):
    out = ctx.outputs.out
    mypy_test = ctx.executable._mypy_test
    junits = depset(transitive = [dep[MypyProvider].trans_junits for dep in ctx.attr.deps])
    template = _test_template.format(
        program = mypy_test.short_path,
        label = ctx.label,
        files = " ".join([j.short_path for j in junits.to_list()]),
    )
    write_runfiles_tmpl(ctx, out, template)

    runfiles = ctx.runfiles(transitive_files = junits)
    runfiles = runfiles.merge(ctx.attr._mypy_test.default_runfiles)
    return [DefaultInfo(executable = out, runfiles = runfiles)]

_dbx_mypy_test = rule(
    implementation = _dbx_mypy_test_impl,
    attrs = _dbx_mypy_test_attrs,
    outputs = {"out": "%{name}.out"},
    test = True,
)

def dbx_mypy_test(
        name,
        deps,
        size = "small",
        tags = [],
        python2_compatible = True,
        python3_compatible = True,
        **kwds):
    things = []
    if python2_compatible:
        if python3_compatible:
            suffix = "-python2"
        else:
            suffix = ""
        things.append((suffix, "2.7"))
    if python3_compatible:
        things.append(("", "3.7"))
    for suffix, python_version in things:
        _dbx_mypy_test(
            name = name + suffix,
            deps = deps,
            size = size,
            tags = tags + ["mypy"],
            python_version = python_version,
            **kwds
        )

# Bootstrap rule to build typeshed.
# This is parameterized by python_version.

def _dbx_mypy_bootstrap_impl(ctx):
    return _dbx_mypy_common_code(
        None,
        ctx,
        [],
        [],
        ctx.files.stub_srcs,
        ctx.attr.python_version,
        False,
    )

_dbx_mypy_bootstrap_attrs = {
    "python_version": attr.string(default = "2.7"),
    "stub_srcs": attr.label_list(allow_files = [".pyi"]),
}
_dbx_mypy_bootstrap_attrs.update(_dbx_mypy_common_attrs)

dbx_mypy_bootstrap = rule(
    implementation = _dbx_mypy_bootstrap_impl,
    attrs = _dbx_mypy_bootstrap_attrs,
)

# mypyc rules

_mypyc_attrs = {
    "deps": attr.label_list(
        providers = [[PyInfo], [DbxPyVersionCompatibility]],
        aspects = [dbx_mypy_aspect],
    ),
    "python_version": attr.string(default = "3.7"),
    "python2_compatible": attr.bool(default = True),
}

_dbx_py_compiled_binary_attrs = dict(dbx_py_binary_attrs)
_dbx_py_compiled_binary_attrs.update(_mypyc_attrs)

def _dbx_py_compiled_binary_impl(ctx):
    if ctx.attr.python2_compatible:
        fail("Compiled binaries do not support Python 2")

    ext_modules = depset(
        transitive = [dep[MypyProvider].trans_ext_modules for dep in ctx.attr.deps],
    )
    return dbx_py_binary_base_impl(ctx, internal_bootstrap = False, ext_modules = ext_modules)

dbx_py_compiled_binary = rule(
    implementation = _dbx_py_compiled_binary_impl,
    attrs = _dbx_py_compiled_binary_attrs,
    toolchains = [CPYTHON_37_TOOLCHAIN_NAME],
    executable = True,
)

_compiled_test_attrs = dict(dbx_py_test_attrs)
_compiled_test_attrs.update(_mypyc_attrs)
dbx_py_compiled_test = rule(
    implementation = _dbx_py_compiled_binary_impl,
    toolchains = [CPYTHON_37_TOOLCHAIN_NAME],
    test = True,
    attrs = _compiled_test_attrs,
)

def dbx_py_compiled_dbx_test(
        name,
        quarantine = {},
        tags = [],
        **kwargs):
    tags = (tags or []) + process_quarantine_attr(quarantine)
    dbx_py_compiled_test(
        name = name,
        quarantine = quarantine,
        tags = tags,
        **kwargs
    )

def _dbx_py_compiled_only_pytest_test(
        name,
        deps = [],
        args = [],
        size = "small",
        services = [],
        start_services = True,
        tags = [],
        test_root = None,
        local = 0,
        flaky = 0,
        quarantine = {},
        python = None,
        python3_compatible = True,
        python2_compatible = False,
        compiled = False,
        plugins = [],
        visibility = None,
        **kwargs):
    if not python3_compatible:
        fail("Compiled tests must support Python 2")

    pytest_args, pytest_deps = extract_pytest_args(args, test_root, plugins, **kwargs)

    tags = tags + process_quarantine_attr(quarantine)

    all_deps = deps + pytest_deps

    if len(services) > 0:
        dbx_py_compiled_dbx_test(
            name = name + "_bin",
            pip_main = "@dbx_build_tools//pip/pytest",
            extra_args = pytest_args,
            deps = all_deps,
            size = size,
            tags = tags + ["manual"],
            local = local,
            quarantine = quarantine,
            python = python,
            python3_compatible = True,
            python2_compatible = False,
            visibility = ["//visibility:private"],
            **kwargs
        )
        dbx_services_test(
            name = name,
            test = name + "_bin",
            services = services,
            start_services = start_services,
            local = local,
            size = size,
            tags = tags,
            flaky = flaky,
            quarantine = quarantine,
            visibility = visibility,
        )
    else:
        dbx_py_compiled_dbx_test(
            name = name,
            pip_main = "@dbx_build_tools//pip/pytest",
            extra_args = pytest_args,
            deps = all_deps,
            size = size,
            tags = tags,
            local = local,
            flaky = flaky,
            python = python,
            python3_compatible = True,
            python2_compatible = False,
            quarantine = quarantine,
            visibility = visibility,
            **kwargs
        )

def dbx_py_compiled_pytest_test(name, compiled_only = False, **kwargs):
    if compiled_only:
        suffix = ""
    else:
        dbx_py_pytest_test(name, **kwargs)
        suffix = "-compiled"
    _dbx_py_compiled_only_pytest_test(name + suffix, **kwargs)
