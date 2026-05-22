# Nangate15 Maintenance Notes

This platform is a practical OpenROAD-flow-scripts packaging of the public
NanGate 15nm Open Cell Library material. Treat it as a research/demo platform,
not as a manufacturable PDK.

## Source Priority

Use this order when deciding whether a platform edit is valid:

1. The local release files in this directory: Liberty, LEF, GDS, Verilog, CDL,
   SPICE, and any release metadata. These are the source of truth for cell names,
   pin names, units, and available views.
2. NCSU FreePDK15 material, because NanGate15 was built around the FreePDK15
   non-manufacturable process.
3. Si2/Silvaco public Open-Cell Library information, especially licensing and
   distribution notes for the 15nm open-cell library.
4. OpenROAD-flow-scripts platform conventions, when adapting the library into an
   ORFS platform.
5. Tool-error-driven compatibility patches, only when the local source views are
   internally inconsistent or incomplete for OpenROAD.

## External References

- NCSU FreePDK15: https://eda.ncsu.edu/freepdk15/
- NanGate 2014 15nm OCL announcement: https://sst.semiconductor-digest.com/2014/05/nangate-releases-15nm-open-source-digital-cell-library/
- Si2 Open Cell and Free PDK Libraries: https://si2.org/open-cell-and-free-pdk-libraries/
- Silvaco and Si2 2019 15nm library announcement: https://www.design-reuse.com/news/6734-silvaco-and-si2-release-unique-free-15nm-open-source-digital-cell-library/
- OpenROAD-flow-scripts upstream: https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts

## Local Compatibility Decisions

- Liberty uses `time_unit : "1ps"`. Project SDC files must use ps values for
  clock periods, clock uncertainty, IO delay, transition limits, and timing
  reports. A 1.0 GHz clock is therefore `1000.0`, not `1.0`.
- `TIEL` uses output pin `ZN` in Liberty, Verilog, SPICE, and CDL. LEF copies
  must expose `PIN ZN` with output direction for OpenROAD consistency checks.
- The released tech LEF had `Via1Array-*` generated-via rules connecting `M1`
  to `MINT2` with cut layer `V1`. `V1` is the cut between `M1` and `MINT1`, so
  `Via1Array-*` should connect `M1` to `MINT1`.
- Some standard-cell M1 pins are 0.028 um wide. The default via metal rectangles
  must not be wider than those pins, or TritonRoute cannot create pin access
  points.
- Small demo designs need a minimum explicit floorplan. Area-driven automatic
  floorplanning can produce a core too narrow for the default PDN stripe grid.
- Global routing is kept on `MINT1..MINT5`, while detailed routing may use `M1`
  for pin access. This avoids global-router guide issues while allowing access
  to M1 standard-cell pins.

## Validation Checklist

After platform edits, run at least:

```sh
export ORFS_ROOT=/OpenROAD-flow-scripts/flow
oproad clean /Users/coding/Documents/ASIC/tmp/dec
oproad synth /Users/coding/Documents/ASIC/tmp/dec
oproad report /Users/coding/Documents/ASIC/tmp/dec
oproad implement /Users/coding/Documents/ASIC/tmp/dec
```

Expected bring-up signs:

- Synthesis STA reports timing in ps and has constrained paths.
- `TIEL` does not produce LEF/Liberty pin-name mismatch warnings.
- Floorplan PDN does not fail with `PDN-0185`.
- Detailed routing completes pin access with `#stdCellPinNoAp = 0`.
- Detailed routing finishes with zero DRC violations for the demo design.
