# Build

```
./buildWASIwasm.sh
```

This will build WASI compiled wasm binary from ngspice source in Linux/Debian based distribution.

# Run

Download previously built `ngspice.wasm` from this repository root directory, Or build and copy it from `ngspice/src/` directory:

Assume that `test.cir` SPICE netlist is placed in `/circuits` directory:

```
wasmtime run --dir /circuits --dir /tmp --dir / --dir /proc ngspice.wasm -b /circuits/test.cir
```

The output files will go to `/` dir.
