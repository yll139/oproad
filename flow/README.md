# bazel-orfs

Bazel front-end for the ORFS Make flow. Designs declared via
`config.mk` are exposed as Bazel targets through
[bazel-orfs](https://github.com/The-OpenROAD-Project/bazel-orfs).

## Targets

For a design at `flow/designs/<platform>/<design>/` with `DESIGN_NAME =
<n>`:

| Target | Output |
|---|---|
| `<n>_synth` | Yosys synthesis |
| `<n>_floorplan` | Floorplan + I/O placement |
| `<n>_place` | Placement |
| `<n>_cts` | Clock tree synthesis |
| `<n>_grt` | Global routing |
| `<n>_route` | Detailed routing |
| `<n>_final` | Final + fill |
| `<n>_generate_abstract` | LEF/LIB abstract |
| `<n>_test` | Full flow + QoR check against `rules-base.json` |
| `<n>_update` | Rebuild and write thresholds back to `rules-base.json` |

Stages depend on the previous, so `_final` runs the whole flow.

```bash
bazelisk build //flow/designs/asap7/gcd:gcd_synth
bazelisk test  //flow/designs/asap7/gcd:gcd_test
bazelisk run   //flow/designs/asap7/gcd:gcd_update
bazelisk query //flow/designs/asap7/...:*
```

## Adding a design

```starlark
# flow/designs/<platform>/<design>/BUILD.bazel
load("//flow/designs:design.bzl", "design")

design()
```

If `flow/designs/src/<n>/BUILD.bazel` is missing, add:

```starlark
load("//flow/designs:design.bzl", "files")

files("verilog")
```

A design counts as CI-tested iff `rules-base.json` exists; without it
the generated targets get `tags = ["manual"]`.

## Parallelism

Each OpenROAD invocation takes `-threads <nproc>`. A wildcard
`bazelisk test` runs designs in parallel and overcommits the host. Cap
with `--jobs=N`.

## Project-level flow knobs

Designs are configured through `config.mk`. The wrapper includes the design
configuration first and the platform configuration second, so project settings
that must extend platform defaults should use append-style variables when
available.

Supported generic knobs added for local project tuning:

- `EXTRA_DONT_USE_CELLS`: appends cells to the platform `DONT_USE_CELLS` list
  after the platform file is included.
- `REPAIR_DESIGN_MAX_WIRE_LENGTH`, `REPAIR_DESIGN_MAX_UTILIZATION`, and
  `REPAIR_DESIGN_ARGS`: extend placement-stage `repair_design` without editing
  `resize.tcl`.
- `CTS_CLUSTER_SIZE`, `CTS_CLUSTER_DIAMETER`, `CTS_BUF_DISTANCE`, and
  `CTS_ARGS`: tune `clock_tree_synthesis`.
- `DETAILED_PLACEMENT_ARGS`: shared detailed-placement arguments for placement,
  CTS legalization, and filler legalization.
- `GLOBAL_ROUTE_ARGS`: explicit global-router arguments for bounded congestion
  exploration.
- `ALLOW_FILLER_ONE_SITE_GAPS`: continue past isolated one-site filler gaps on
  platforms whose filler libraries cannot legally fill them.

Keep these settings in the design or platform `config.mk` so synthesis,
implementation, and report runs remain reproducible.
