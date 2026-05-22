# NanGate 15nm OpenROAD platform

This directory repackages `NanGate_15nm_OCL_v0.1_2014_06_Apache.A` into an
OpenROAD-flow-scripts style platform directory.

## Contents

- `config.mk`: OpenROAD platform entry point.
- `lef/`: technology LEF and standard-cell LEF. The source tech LEF had dangling
  `MINT6/VINT5` via-rule references; this platform copy keeps only the released
  `M1..MINT5` layer stack.
- `lib/`: NLDM Liberty corners, with `NanGate_15nm_OCL_typical.lib` selected by
  default in `config.mk`.
- `gds/`: merged standard-cell GDS.
- `verilog/`: original functional Verilog cell models from the release bundle.
- `work_around_yosys/`: Liberty-derived blackbox cell declarations that avoid
  Yosys parsing issues with the release bundle's UDP primitives.
- `spice/cell/`: per-cell SPICE netlists from the release bundle.
- `cdl/`: merged CDL/SPICE netlist for flows that expect a single file.
- `cells_*.v`: Yosys techmap helpers for latches, clock gates, and adders.
- `make_tracks.tcl`, `fastroute.tcl`, `grid_strategy-M1-MINT2-MINT5.tcl`,
  `setRC.tcl`: OpenROAD helper scripts adapted to the 15nm layer names.
- `MAINTENANCE.md`: source hierarchy, external references, and local compatibility
  decisions used when maintaining this platform.

## Notes

The public 15nm OCL bundle does not include dedicated tap/endcap cells, KLayout
DRC/LVS decks, or calibrated OpenRCX rules. `tapcell.tcl` is therefore a no-op,
and `setRC.tcl` contains bring-up estimates only.
