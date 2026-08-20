# `GCOV`

Kleaf supports GCOV profiling via two flags:

*   `--gcov_mode`: A string flag for finer-grained control. It supports the following values:
    *   `default`: (Default) Do not enable GCOV.
    *   `enabled`: Enable GCOV profiling (sets `CONFIG_GCOV_KERNEL=y`). GCOV profiling will only run on modules that explicitly select it (e.g. via `ddk_module(gcov="always")`).
    *   `profile_all`: Enable GCOV profiling on the entire kernel and all modules (sets both `CONFIG_GCOV_KERNEL=y` and `CONFIG_GCOV_PROFILE_ALL=y`).
*   `--gcov`: (Deprecated) A boolean flag. If `--gcov` is set to true, it behaves exactly like `--gcov_mode=profile_all` (enables GCOV and profiles the entire kernel/modules). Use `--gcov_mode` instead.

For example, to build with profiling enabled for all modules:

```shell
$ tools/bazel build --gcov_mode=profile_all //common:kernel_aarch64
# Or equivalently (deprecated):
$ tools/bazel build --gcov //common:kernel_aarch64
```

You may find the `*.gcno` files under the
`bazel-bin/<package_name>/<target_name>/<target_name>_gcno` directory,
where `<target_name>` is the name of the `kernel_build()`
macro. In the above example, the `.gcno` files can be found at

```
bazel-bin/common/kernel_aarch64/kernel_aarch64_gcno/
```

... or in `destdir`.

## Handling path mapping

After you boot up the kernel and [mount debugfs](https://docs.kernel.org/filesystems/debugfs.html):

```shell
$ mount -t debugfs debugfs /sys/kernel/debug
```

You may see gcno files under:

```
/sys/kernel/debug/gcov/<some_host_absolute_path_to_repository>/<some_out_directory>/common/<some_source_file>.gcno
```

To map between these paths to the host, consult the `gcno_mapping.<name>.json`
under `bazel-bin/`.

### GKI

In the above example, the file can be found after a build:

```shell
$ tools/bazel build --gcov_mode=profile_all //common:kernel_aarch64
[...]
$ cat bazel-bin/common/kernel_aarch64/gcno_mapping.kernel_aarch64.json
[...]
```

You may also find this file under `destdir`:

```shell
$ tools/bazel run //common:kernel_aarch64_dist -- --destdir=out/kernel_aarch64/dist
[...]
$ cat out/kernel_aarch64/dist/gcno_mapping.kernel_aarch64.json
[...]
```

### Device mixed builds

You need to consult the JSON file for the device `kernel_build`.
Using virtual device as an example, you may find the files under:

```shell
$ tools/bazel build --gcov_mode=profile_all //common-modules/virtual-device:virtual_device_x86_64
[...]
$ cat bazel-bin/common-modules/virtual-device/virtual_device_x86_64/gcno_mapping.virtual_device_x86_64.json
[...]
```

Or under `destdir`:

```shell
$ tools/bazel run --gcov_mode=profile_all //common-modules/virtual-device:virtual_device_x86_64_dist -- --destdir=out/vd/dist
[...]
$ cat out/vd/dist/gcno_mapping.virtual_device_x86_64.json
[...]
```

**Note**: You will also see `gcno_mapping.kernel_x86_64.json` under `destdir`. That file is incomplete
as it does not contain mappings for in-tree modules specific for virtual device.

### Sample content of `gcno_mapping.<name>.json`:

Without `--config=local` (see [sandboxing](sandbox.md)):

```json
[
  {
    "from": "/<repository_root>/out/bazel/output_user_root/.../__main__/out.../android-mainline/common",
    "to": "bazel-out/.../kernel_x86_64/gcno"
  }
]
```

With `--config=local` (see [sandboxing](sandbox.md)):

```json
[
  {
    "from": "/mnt/sdc/android/kernel/out/cache/.../common",
    "to": "bazel-out/k8-fastbuild/bin/common/kernel_aarch64/gcno"
  }
]
```

The JSON file contains a list of mappings. Each mapping indicates that the `.gcno` files
located in `<from>` were copied to `<to>`. Hence, `/sys/kernel/debug/<from>`
on the device maps to `<to>` on host.

**Note**: For both `<from>` and `<to>`, absolute paths should be interpreted as-is,
and relative paths should be interpreted as relative to the repository on host. For example:

```json
[
  {
    "from": "/absolute/from",
    "to": "/absolute/to"
  },
  {
    "from": "relative/from",
    "to": "relative/to"
  }
]
```

This means:
* Device `/sys/kernel/debug/absolute/from` maps to host `/absolute/to`
* Device `/sys/kernel/debug/<repositry_root>/relative/from` maps to host `/<repository_root>/relative/to`.

## ddk_module

To control GCOV profiling for a specific `ddk_module`, set the `gcov` attribute. It supports the following values:

*   `inherit` (default): Inherit GCOV configuration from parent configurations.
    *   If the `--gcov_mode` flag is set to `profile_all` (or the legacy `--gcov` flag is set to true), GCOV profiling is enabled for this module.
    *   If the `--gcov_mode` flag is set to `enabled` or `default` (and the legacy `--gcov` flag is set to false), GCOV profiling is NOT enabled for this module.
*   `always`: Enable GCOV profiling for this module as long as GCOV is enabled globally (i.e., the `--gcov_mode` flag is set to `enabled` or `profile_all`, or the legacy `--gcov` flag is set to true).
*   `never`: Never enable GCOV profiling for this module, regardless of global flags.

For details, see the `gcov` attribute documentation in [`ddk_module`](api_reference.md#ddk_module).

