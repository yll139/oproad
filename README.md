# oproad

`oproad` is a small Docker-only wrapper around OpenROAD-flow-scripts for local
ASIC experiments. The host machine only needs Git and Docker. OpenROAD, Yosys,
Icarus Verilog, make, and the supported platform files live inside the Docker
image.

Supported host systems:

- macOS and Linux: `./oproad`
- Windows PowerShell: `.\oproad.ps1`
- Windows cmd.exe: `oproad.cmd`

Supported platforms included in this repo:

- `nangate45`
- `nangate15`

## Build

```bash
git clone https://github.com/yll139/oproad.git
cd oproad
./oproad build-image
```

On Windows PowerShell:

```powershell
git clone https://github.com/yll139/oproad.git
cd oproad
.\oproad.ps1 build-image
```

The default Docker image tag is `oproad:latest`. Override it with
`OPROAD_IMAGE` if needed.

## Create a Project

Only project creation specifies the process/platform:

```bash
./oproad new nangate15 dec 1.0 ./workspace
```

This creates `./workspace/dec`. The selected platform and design are stored in
`./workspace/dec/.asic_project`.

After that, commands read the project metadata automatically. Do not pass the
platform again:

```bash
./oproad sim ./workspace/dec
./oproad synth ./workspace/dec
./oproad report ./workspace/dec
./oproad implement ./workspace/dec
./oproad clean ./workspace/dec
```

If your shell is already inside the project directory, the project argument is
optional:

```bash
cd ./workspace/dec
../../oproad synth
../../oproad report
```

## Delete a Project

```bash
./oproad delete ./workspace/dec
```

Always delete projects through the host-side `oproad` script instead of manually
removing the directory. The wrapper mounts the project into Docker and the
runner also creates matching ORFS working copies, result folders, reports, logs,
and objects inside the container runtime. `oproad delete` removes the local
project directory and asks the container runner to clean the corresponding ORFS
copies in the same operation.

## Finish Mode

By default, `nangate15` uses a light finish stage that produces final reports,
netlist, DEF, and ODB while skipping GDS/KLayout merge. To force full finish:

```bash
OPROAD_FINISH_MODE=full ./oproad implement ./workspace/dec
```

Valid values are `auto`, `light`, `full`, and `skip`.

## Shell

To inspect the container manually:

```bash
./oproad shell .
```

Users should run `oproad` only on the host. Inside the container, the host
wrapper calls `oproad-runner` as an implementation detail alongside `openroad`,
`yosys`, and `iverilog`.

## VS Code

VS Code tasks are included under `.vscode/tasks.json`. Open this repository in
VS Code and use `Terminal -> Run Task...` to build the image, create projects,
simulate, synthesize, report, implement, clean, delete, or open a container
shell.

These tasks still call the host-side `oproad` wrapper. Project directories are
bind-mounted into Docker, so VS Code edits and container-generated outputs stay
synchronized on the host filesystem.

See [docs-vscode.md](./docs-vscode.md).
