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

After installation:

```bash
./oproad new nangate45 mydesign 1.0   # Create a project
./oproad menu                          # Interactive menu for all operations
```

## Recommended Editor: VS Code

This project is designed to work best with **Visual Studio Code**. The
repository includes built-in task definitions and an interactive button menu
that are automatically available when you open the project in VS Code.

To get started:

```bash
# Open the project in VS Code
code oproad.code-workspace
```

Then use **Terminal → Run Task... → oproad: menu** to see clickable buttons for
all operations — no command typing needed.

VS Code also provides syntax highlighting for Verilog/SystemVerilog and
built-in Git integration, making it the most convenient editor for this
workflow.

---

## Project File Sync (How It Works)

Files stay synchronized between your host machine and the Docker container
through a **two-layer mechanism**:

```
Host (edit files in VS Code)
    │  docker bind mount (-v)
    ▼
Container /project/
    │  rsync (sync_project_to_orfs)
    ▼
Container /OpenROAD-flow-scripts/flow/designs/   ← ORFS toolchain reads/writes here
    │  rsync (sync_orfs_to_project)
    ▼
Container /project/
    │  docker bind mount (-v)
    ▼
Host (view results, reports, logs)
```

### Layer 1: Docker Bind Mount

When you run any `oproad` command, the script mounts your project directory
into the container with `-v host_path:/project`. This means:

- **Real-time, bidirectional** — edit a file on the host, the container sees it
  immediately; the container writes a result, you see it on the host instantly.
- **No manual copy** — no `docker cp` needed.
- **Data stays on the host** — deleting the container does not delete files.

### Layer 2: ORFS Directory Sync

ORFS requires source files under `designs/src/<design>/` and configuration
under `designs/<platform>/<design>/`. Before running a tool, `runner.sh`
copies your files to these locations with `rsync`, runs the toolchain, then
copies results back:

| Project Directory | Synced To (ORFS) | Direction |
|---|---|---|
| `src/` | `designs/src/<design>/` | project → ORFS |
| `platform/<plat>/<design>/` | `designs/<plat>/<design>/` | project → ORFS |
| `results/<plat>/<design>/` | `results/<plat>/<design>/` | ORFS → project |
| `reports/<plat>/<design>/` | `reports/<plat>/<design>/` | ORFS → project |
| `logs/<plat>/<design>/` | `logs/<plat>/<design>/` | ORFS → project |
| `objects/<plat>/<design>/` | `objects/<plat>/<design>/` | ORFS → project |

### Project Directory Structure

After creating a project, the following layout is generated:

```
projects/<design>/
├── .asic_project          ← Platform, design name, frequency
├── src/
│   ├── rtl/               ← Your Verilog RTL source files
│   ├── tb/                ← Testbenches
│   ├── include/           ← Include files
│   └── scripts/           ↑ Simulation / custom scripts
├── platform/
│   └── <platform>/
│       └── <design>/
│           ├── config.mk      ← ORFS build configuration
│           └── constraint.sdc ← Timing constraints
├── results/
│   └── <platform>/<design>/  ← Synthesis / implementation outputs
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

Projects are automatically created under the `projects/` directory:

```bash
./oproad new <platform> <design> <freq_GHz>
```

This is the only step that specifies the platform/process. A typical first
project is:

```bash
./oproad new nangate45 mydesign 1.0
```

Which creates:

```text
projects/mydesign/
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

Run the physical implementation flow:

```bash
./oproad implement ./projects/<design>
```

Clean generated flow outputs while keeping the project source:

```bash
./oproad clean ./projects/<design>
```

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

#### Interactive Menu (Zero Setup)

For an interactive button-style menu in the terminal, run:

```bash
./oproad menu
```

Or in VS Code, run **Terminal → Run Task... → oproad: menu**. The menu shows
numbered options for all operations and lets you switch between projects.

This works immediately with no extensions or additional setup.

VS Code itself lists tasks through menus rather than showing task buttons by
default. This repository recommends the `Taskbar` extension; after installing
the recommended extensions, open the Explorer sidebar and use the Taskbar view to
run the `oproad:*` tasks from clickable entries.

## VS Code

VS Code tasks are included under `.vscode/tasks.json`. Open this repository in
VS Code and use:

```text
Terminal -> Run Task...
```

For visible task buttons, install the recommended `Taskbar` extension when VS
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

## Difference From The Original Fork / Upstream ORFS

This repository was forked from OpenROAD-flow-scripts, but it is no longer meant
to be used like a normal ORFS checkout. It keeps the ORFS flow engine, scripts,
and platform structure, while changing the installation model and the user
interface:

- Original ORFS: users may install tools in several ways and often run ORFS
  Make targets directly.
- This repo: users build one Docker image and then call only the host-side
  `oproad` wrapper.
- Original ORFS: example designs usually live inside `flow/designs`.
- This repo: user projects live under `projects/<design>` outside the ORFS flow
  tree.
- Original ORFS: platform/design variables are commonly passed through Make
  variables or design config files.
- This repo: `oproad new` records the platform, design name, target frequency,
  and timing unit in `.asic_project`; later commands reuse that metadata.
- Original ORFS: cleanup usually targets ORFS build directories.
- This repo: `oproad delete` removes both the host project and the matching
  container-side ORFS working data, so manual folder deletion is discouraged.
- Original ORFS: the repository contains broad development and regression
  infrastructure.
- This repo: the checked-in surface is trimmed toward local project creation and
  Docker execution, while keeping the platform directories.
- This repo adds VS Code tasks for users who prefer `Terminal -> Run Task...`
  over command-line typing.
- The Docker image defaults to `openroad/orfs:latest`; `oproad build-image` can
  select another ORFS base tag/image and can auto-detect or override the Docker
  platform.

## Fork Source

This repository was forked from OpenROAD-flow-scripts state:

```text
commit: bd2a6b695156e957a332e644e2c1587a74fd705f
date:   2026-05-21T13:54:30Z
title:  Merge pull request #4050 from The-OpenROAD-Project-staging/secure-fix_missing_para_dbmodnet
```

The Docker-only `oproad` conversion was committed on:

```text
2026-05-22T10:50:44+08:00
```
