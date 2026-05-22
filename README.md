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


**Important:** All projects must be created inside the `projects` directory. If you use the command line (`oproad new ...`), the project will be automatically placed under `projects/` in your current working directory.

After installation:

```bash
./oproad new nangate45 mydesign 1.0   # Create a project (will be placed in ./projects/mydesign)
```


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

---

## VS Code Integration

VS Code is recommended for the best experience. The repository includes built-in task definitions and interactive menus. Open the project in VS Code and use **Terminal → Run Task...** or the Taskbar extension for one-click operations. See [docs-vscode.md](./docs-vscode.md) for more details.
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

