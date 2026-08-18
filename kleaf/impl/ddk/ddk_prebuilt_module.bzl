# Copyright (C) 2026 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Wraps prebuilt DDK module files, so it can be used as a dependency."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load(
    ":common_providers.bzl",
    "CompileCommandsInfo",
    "DdkConfigInfo",
    "DdkHeadersInfo",
    "DdkLibraryInfo",
    "GcovInfo",
    "KernelBuildUnameInfo",
    "KernelCmdsInfo",
    "KernelModuleInfo",
    "KernelModuleSetupInfo",
    "KernelUnstrippedModulesInfo",
    "ModuleSymversFileInfo",
    "ModuleSymversInfo",
)
load(
    ":ddk/copy_ddk_prebuilts.bzl",
    "copy_ddk_prebuilt",
    "copy_prebuilts_to_staging",
)
load(":ddk/ddk_config/ddk_config_info_subrule.bzl", "empty_ddk_config_info")
load(":ddk/ddk_headers.bzl", "ddk_headers_common_impl")
load(":hermetic_toolchain.bzl", "hermetic_toolchain")

visibility("//build/kernel/kleaf/...")

# Empty providers needed for kernel_module_group compatibility
_empty_compile_commands_info = CompileCommandsInfo(infos = depset())
_empty_ddk_headers_info = DdkHeadersInfo(include_infos = depset(), files = depset())
_empty_modules_symver_file_info = ModuleSymversFileInfo(module_symvers = depset())
_empty_modules_symver_info = ModuleSymversInfo(restore_paths = depset())
_empty_ddk_library_info = DdkLibraryInfo(files = depset())
_empty_gcov_info = GcovInfo(gcno_mapping = "", gcno_dir = None)
_empty_kernel_cmds_info = KernelCmdsInfo(srcs = depset(), directories = depset())
_empty_kernel_module_setup_info = KernelModuleSetupInfo(inputs = depset(), setup = "")
_empty_kernel_unstripped_modules_info = KernelUnstrippedModulesInfo(directories = depset())

def _ddk_prebuilt_module_impl(ctx):
    hermetic_tools = hermetic_toolchain.get(ctx)

    out_stem = ctx.file.src.basename.removesuffix("." + ctx.file.src.extension)
    ext_mod = paths.join(ctx.label.repo_name, ctx.label.package)
    all_files = []
    infos = []

    # Required output
    module_ko = copy_ddk_prebuilt(
        hermetic_tools,
        ctx.file.src,
        "{}/{}.ko".format(ctx.label.name, out_stem),
        "Ko",
    )
    all_files.append(module_ko)

    # ModuleSymversFileInfo
    if ctx.file.module_symvers:
        module_symvers = copy_ddk_prebuilt(
            hermetic_tools,
            ctx.file.module_symvers,
            "{}/{}_Module.symvers".format(ctx.label.name, out_stem),
            "ModuleSymvers",
        )
        module_symvers_name = module_symvers.basename
        module_symvers_restore_path = paths.join(ext_mod, module_symvers_name)
        setup_command = """
        (
            # Create directories if not present.
            mkdir -p ${{ROOT_DIR}}/{ext_mod}
            # Restore Modules.symvers
            mkdir -p $(dirname ${{COMMON_OUT_DIR}}/{module_symvers_restore_path})
            rsync -aL {module_symvers} ${{COMMON_OUT_DIR}}/{module_symvers_restore_path}
        )
        """.format(
            ext_mod = ext_mod,
            module_symvers = module_symvers.path,
            module_symvers_restore_path = module_symvers_restore_path,
        )
        all_files.append(module_symvers)
        infos.append(ModuleSymversFileInfo(module_symvers = depset([module_symvers])))
        infos.append(ModuleSymversInfo(restore_paths = depset([module_symvers_restore_path])))
        infos.append(KernelModuleSetupInfo(inputs = depset([module_symvers]), setup = setup_command))
    else:
        infos.append(_empty_modules_symver_file_info)
        infos.append(_empty_modules_symver_info)
        infos.append(_empty_kernel_module_setup_info)

    # DdkConfigInfo
    if ctx.attr.config:
        infos.append(ctx.attr.config[DdkConfigInfo])
    else:
        infos.append(empty_ddk_config_info(kernel_build_ddk_config_env = None))

    # DdkHeadersInfo
    if ctx.attr.hdrs or ctx.attr.includes or ctx.attr.linux_includes:
        ddk_headers_info = ddk_headers_common_impl(
            ctx.label,
            ctx.attr.hdrs,
            ctx.attr.includes,
            ctx.attr.linux_includes,
        )
        infos.append(ddk_headers_info)
    else:
        infos.append(_empty_ddk_headers_info)

    # Recreate modules_install
    modules_order = copy_ddk_prebuilt(
        hermetic_tools,
        ctx.file.modules_order,
        "{}/modules.order".format(ctx.label.name),
        "ModulesOrder",
    )
    modules_staging_dws = copy_prebuilts_to_staging(
        hermetic_tools,
        [ctx.file.src, ctx.file.modules_order],
        ctx.attr.kernel_build[KernelBuildUnameInfo].kernel_release,
        ext_mod,
    )
    _kernel_module_info = KernelModuleInfo(
        kernel_build_infos = None,
        modules_staging_dws_depset = depset([modules_staging_dws]),
        kernel_uapi_headers_dws_depset = depset(),
        files = depset([module_ko]),
        packages = depset([ext_mod]),
        label = ctx.label,
        modules_order = depset([modules_order]),
        transitive_files = depset([module_ko]),
    )

    infos.append(DefaultInfo(files = depset(all_files)))

    # Add empty but neccesary infos for kernel_module_group
    infos.extend([
        _empty_compile_commands_info,
        _empty_ddk_library_info,
        _empty_gcov_info,
        _empty_kernel_cmds_info,
        _empty_kernel_unstripped_modules_info,
        _kernel_module_info,
    ])
    return infos

ddk_prebuilt_module = rule(
    implementation = _ddk_prebuilt_module_impl,
    doc = """Wraps ddk_module prebuilt files so it can be used in [ddk_module.deps](#ddk_module-deps).

        Example:

        ```
        # Optional
        ddk_config(
            name = "foo_config",
        )
        ddk_prebuilt_module(
            name = "foo",
            src = "foo.ko",
            module_symvers = "foo_Module.symvers",
            config = ":foo_config", # Optional
        )
        ```
    """,
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The .ko file.",
        ),
        "module_symvers": attr.label(
            allow_single_file = True,
            doc = "Module.symvers file.",
        ),
        "modules_order": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "modules.order file.",
        ),
        "config": attr.label(
            doc = "A [ddk_config](#ddk_config).",
            providers = [DdkConfigInfo],
        ),
        "hdrs": attr.label_list(
            allow_files = True,
            doc = "[ddk_headers.hdrs](#ddk_headers-hdrs)",
        ),
        "includes": attr.string_list(
            doc = "[ddk_headers.hdrs](#ddk_headers-includes)",
        ),
        "linux_includes": attr.string_list(
            doc = "[ddk_headers.hdrs](#ddk_headers-linux_includes)",
        ),
        "kernel_build": attr.label(
            doc = "The [`kernel_build`](#kernel_build).",
            mandatory = True,
            # The minimum requirement is KernelBuildUnameInfo provider to
            #  get the kernel_release value [0].
            # https://source.android.com/docs/core/architecture/kernel/gki-versioning#kernel-release
            providers = [KernelBuildUnameInfo],
        ),
    },
    subrules = [
        copy_ddk_prebuilt,
        copy_prebuilts_to_staging,
        empty_ddk_config_info,
    ],
    toolchains = [hermetic_toolchain.type],
)
