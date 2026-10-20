#!/bin/sh
# Generate CSR RTL, register documentation, and testbench.
set -e
cd "$(dirname "$0")"
python3 gen_csr.py tj_ctrl_csr.yaml \
  --out-rtl ../rtl/csr \
  --out-doc ../doc \
  --out-tb  ../tb/csr
