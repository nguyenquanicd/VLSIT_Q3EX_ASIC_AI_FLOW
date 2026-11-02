# Open questions — Test programs

_No open questions._

# Closed

- **PRE1** No trained INT8 MNIST weights or real MNIST test images were provided, so TC-056/057 run on a deterministic synthetic network and synthetic images (bit-exact check, label spread over 5 digits). Do you want to supply a real export? → Synthetic placeholder data is used; the Makefile accepts a real export with MODEL=<file.npz> (arrays w1 (128,784), b1, w2 (10,128), b2, images (N<=100,784), optional shift1/shift2). _(default accepted)_
- **PRE2** src/tb/run.sh invokes only `simv +TC=TC-056/057`, but the testbench reads the MNIST files only from plusargs (+FW_HEX, +DMEM_HEX, +IMG_HEX, +EXP_HEX, +IMG_ADDR, +LOGIT_ADDR). Who passes them? → The regression runner appends the contents of build/tb/programs/mnist.plusargs to the simv command line for TC-056 and TC-057. _(default accepted)_

_Answer with `q3tui answer <ID> "..."` or in the TUI (Questions tab)._
