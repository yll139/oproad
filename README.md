# oproad

`oproad` is a Docker-only host wrapper for local ASIC experiments with
OpenROAD-flow-scripts. Users run `oproad` on the host machine; the Docker
container provides the EDA runtime with OpenROAD, Yosys, Icarus Verilog, make,
Python, and platform data.

Supported hosts:

- macOS and Linux: `./oproad`
- Windows cmd.exe: `oproad.cmd`

## Prerequisites

- **Docker Desktop**: must be installed, running, and logged in to Docker Hub.
  - [Download Docker Desktop](https://www.docker.com/products/docker-desktop/)
  - After installation, open Docker Desktop and sign in (or run `docker login`).
  - On Apple Silicon (M1/M2/M3), Docker Desktop can run `linux/amd64` images
    through emulation when `linux/arm64` images are not available.
- **Git**: to clone this repository.
- **VS Code (optional)**: works best with the included task definitions.

## Quick Start (One Command)

```bash
git clone https://github.com/yll139/oproad.git
cd oproad
./install.sh
```

The install script will:
1. Check prerequisites (Docker Desktop, Git)
2. Build the Docker image (auto-detects platform and available ORFS images)
3. Detect VS Code and create a workspace file with task buttons
4. Show next steps




**Important:** All projects must be created and managed inside the `oproad/projects` directory. The `oproad new` command only allows creating new projects under `oproad/projects`, and all VS Code tasks and related operations must also point to projects in this directory.



After installation:

```bash
./oproad new nangate45 mydesign 1.0   # Project will only be created under ./projects/mydesign
```


---

## Project File Sync (How It Works)

Files stay synchronized between your host machine and the Docker container
through a **two-layer mechanism**:

```
Host (edit files in VS Code)
   │
   │  docker bind mount (-v)
   ▼
Container /project/
   │
   │  rsync (sync_project_to_orfs)
   ▼
Container /OpenROAD-flow-scripts/flow/designs/   ← ORFS toolchain reads/writes here
   │
   │  rsync (sync_orfs_to_project)
   ▼
Container /project/
   │
   │  docker bind mount (-v)
   ▼
Host (view results, reports, logs)
```

---

## VS Code Integration

VS Code is recommended for the best experience. This repository provides built-in task definitions, workspace settings, and interactive menus.

**How to use with VS Code:**

1. **Open the Workspace:**
    - Open the repository folder in VS Code, or for best results, open the `oproad.code-workspace` file (File → Open Workspace... → select `oproad.code-workspace`).
    - This will automatically load recommended settings, tasks, and extensions.

2. **Run Tasks:**
    - Use the menu: `Terminal → Run Task...` to see all `oproad:*` tasks (build image, new project, simulate, synthesize, report, implement, clean, delete, shell, menu, etc).
    - For one-click task buttons, install the [Taskbar](https://marketplace.visualstudio.com/items?itemName=philippscheer.taskbar) extension (VS Code will prompt you to install recommended extensions).

3. **Workspace Defaults:**
    - The default workspace directory is the cloned `oproad` folder.
    - The default project parent path is `projects`.
    - The default project name is `test` (see `oproad.code-workspace`).

4. **More Information:**
    - See [docs-vscode.md](./docs-vscode.md) for details.

Example directory structure:

```
├── reports/
│   └── <platform>/<design>/  ← Timing and area reports
├── logs/
│   └── <platform>/<design>/  ← Tool logs
└── objects/
     └── <platform>/<design>/  ← Intermediate build artifacts
```

---

## Detailed Usage

### 1. Bootstrap The Docker Toolchain

Clone the repository and build the local Docker image once:

```bash
git clone https://github.com/yll139/oproad.git
cd oproad
./oproad build-image
```

`build-image` can also take an ORFS Docker base version and container platform:

```bash
./oproad build-image latest auto
./oproad build-image v3.0-1305-g0aa3fe5d linux/amd64
./oproad build-image openroad/orfs:latest linux/arm64
```

The Docker platform defaults to `auto`. It maps Intel/AMD x86_64 hosts to
`linux/amd64` and Apple Silicon/ARM64 hosts to `linux/arm64`. Some ORFS base
images may only publish one architecture; if Docker reports that the selected
platform is unavailable, rebuild with an explicit platform supported by that
image. Docker Desktop can run `linux/amd64` images on Apple Silicon through
emulation when needed. The selected ORFS base image, requested platform, and
resolved platform are written to `.oproad-config` so later commands reuse them.

### 2. Create A Project



All projects must be created under the `oproad/projects` directory. For example:

```bash
./oproad new nangate45 mydesign 1.0
# The result directory will be oproad/projects/mydesign
```

Example directory structure:

```text
oproad/projects/mydesign/
├── .asic_project          ← Platform, design name, frequency
├── src/rtl/               ← Your Verilog RTL source files
├── src/tb/                ← Testbenches
├── platform/<platform>/   ← Config.mk and timing constraints
├── results/               ← Synthesis / implementation outputs
├── reports/               ← Timing and area reports
├── logs/                  ← Tool logs
└── objects/               ← Intermediate build artifacts
```

### 3. Edit, Simulate, Synthesize, And Implement

Edit the generated RTL and testbench under:

```text
projects/<design>/src
```

Run simulation:

```bash
./oproad sim ./projects/<design>
```

Run synthesis:

```bash
./oproad synth ./projects/<design>
```

Print the current timing/report summary:

```bash
./oproad report ./projects/<design>
```

Use the health checks in the report before comparing designs:

- `STA health result: PASS` means timing has linked the top module, read Liberty
  and SDC, found constrained paths, and did not report unclocked or
  unconstrained endpoints.
- `Area health result: PASS` means summed netlist cell area has full Liberty
  coverage and matches the native Yosys/OpenROAD area report.
- Synthesis timing is pre-layout and useful for architecture exploration. Use
  implementation timing for routed timing; the report warns when final SPEF
  parasitics are missing.

Run the physical implementation flow:

```bash
./oproad implement ./projects/<design>
```

Clean generated flow outputs while keeping the project source:

```bash
./oproad clean ./projects/<design>
```

`clean` removes generated project outputs and the matching OpenROAD-flow-scripts
working copies used by the Docker container. Use it before collecting final
metrics so stale synced results, reports, logs, or objects cannot affect the
next run.

After project creation, do not pass the platform again. All later commands read
`.asic_project`.

If the shell is already inside the project directory, the project argument is
optional:

```bash
cd ./projects/<design>
../../oproad synth
../../oproad report
```

### 4. Delete Projects Through The Wrapper

Delete projects through `oproad`, not by manually removing folders:

```bash
./oproad delete ./projects/<design>
```

The wrapper bind-mounts the local project into Docker. During runs, the
container also creates matching ORFS working copies, results, reports, logs, and
objects. `oproad delete` removes the host project and asks the container runner
to clean the matching ORFS-side copies in the same operation.

### 5. VS Code Workflow

Open the cloned repository folder in VS Code, then use:

```text
Terminal -> Run Task...
```

The VS Code tasks call the same host-side wrapper and use the same Docker image.
They provide button-style entries for image build, project creation, simulation,
synthesis, report, implementation, clean, delete, and shell.

### 6. Reading Results

Use `oproad report` as the metric reference after `synth` or `implement`:

```bash
./oproad report ./projects/<design>
```

The report summary includes the PDK/platform, clock period, target frequency,
OpenSTA setup WNS/TNS, worst setup slack, hold WHS/THS, worst slack across all
checks, critical path delay, estimated Fmax, Liberty cell-area sum, NAND2
equivalent count, DFF count, and total standard cell count.

For final comparisons, prefer:

- `Design area (Liberty)`: authoritative summed standard-cell area.
- `Estimated NAND2 equivalent`: area divided by the platform NAND2_X1 area.
- `WNS (OpenSTA)` / `TNS (OpenSTA)`: setup violation summary. These can be
  `0.00` when there is no setup violation.
- `Worst setup slack`: real worst setup/max-path slack, including positive
  margin. Use this to see how much setup timing margin remains.
- `WHS (hold)` / `THS (hold)`: hold margin and total hold violation summary.
- `Critical delay`: OpenSTA's reported setup critical-path arrival/delay.
- `Worst slack (all)`: includes min-delay checks; review it separately from
  setup WNS/TNS and worst setup slack.

If the report says final SPEF is missing, timing is post-route with estimated
routing parasitics. It is still useful for exploration, but not a sign-off RC
extraction result.

### 7. Common Flow Configuration Knobs

Project configuration lives in:

```text
projects/<design>/platform/<platform>/<design>/config.mk
```

Useful generic knobs supported by this wrapper and the bundled flow scripts:

- `DONT_BUFFER_PORTS = 1`: skips automatic top-level port buffering for
  block-level designs.
- `REPAIR_DESIGN_MAX_WIRE_LENGTH`, `REPAIR_DESIGN_MAX_UTILIZATION`, and
  `REPAIR_DESIGN_ARGS`: pass bounded options into placement-stage
  `repair_design`.
- `CTS_CLUSTER_SIZE`, `CTS_CLUSTER_DIAMETER`, `CTS_BUF_DISTANCE`, and
  `CTS_ARGS`: tune clock-tree synthesis.
- `DETAILED_PLACEMENT_ARGS`: passes options into detailed placement in the
  placement, CTS, and filler stages.
- `GLOBAL_ROUTE_ARGS`: passes explicit global-router options, for example a
  bounded congestion-iteration policy.
- `ALLOW_FILLER_ONE_SITE_GAPS = 1`: lets the flow continue when the platform has
  no legal filler for isolated one-site gaps.
- `EXTRA_DONT_USE_CELLS`: appends project-specific cells to the platform
  `DONT_USE_CELLS` list without replacing platform defaults.


### 8. Console Menu (Zero Setup)

For a simple interactive console menu in the terminal, run:

```bash
./oproad menu
```

Or in VS Code, run **Terminal → Run Task... → oproad: menu**. This menu provides numbered options for all main operations and lets you switch between projects. It does not display project paths or workspace information—it's just a convenient console launcher for common tasks.

This works immediately with no extensions or additional setup.

VS Code itself lists tasks through menus rather than showing task buttons by
default. This repository recommends the `philippscheer.taskbar` extension; after installing
the recommended extensions, open the Explorer sidebar and use the Taskbar view to
run the `oproad:*` tasks from clickable entries.

## VS Code

VS Code tasks are included under `.vscode/tasks.json`. Open this repository in
VS Code and use:

```text
Terminal -> Run Task...
```

For visible task buttons, install the recommended `philippscheer.taskbar` extension when VS
Code prompts for workspace recommendations. The Taskbar view reads
`.vscode/tasks.json` and shows the `oproad:*` tasks in the sidebar.

The tasks call the same host-side wrapper and bind-mount the same local project
directory, so files edited in VS Code and files generated in Docker stay
synchronized on the host filesystem.

Available tasks include image build, new project, simulate, synthesize, report,
implement, clean, delete project, and container shell. The default VS Code
workspace directory is the cloned repository folder `oproad`, the default
project parent path inside that workspace is `projects`, the default
project/design name is `test`, and the default project root is:

```text
projects/test
```

Seen from the parent directory that contains the clone, the same project path is
`oproad/projects/test`.

See [docs-vscode.md](./docs-vscode.md).
