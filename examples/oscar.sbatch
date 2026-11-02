#!/bin/bash
# Event displays on Brown's Oscar cluster. Run from the repository directory:
#
#   sbatch examples/oscar.sbatch --file /path/ZD4007_25_AL.root --entry 22624
#
# Every argument is passed on to edisplay.jl. Searching for --event RUN:EVENT in many files reads
# their headers only, but give it the files of the right run period, not a whole year.
#SBATCH --job-name=edisplay
#SBATCH --partition=batch
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:30:00
#SBATCH --output=edisplay_%j.out
set -euo pipefail
# `module load root` does not work on Oscar; use the spack ROOT directly.
ROOTSYS=/oscar/rt/9.6/25/spack/x86_64_v3/root-6.28.12-35q2ij6mjlcgvo3uqpohib3fuyku3gja
VDT=/oscar/rt/9.6/25/spack/x86_64_v3/vdt-0.4.6-5cso4u2hsllvrh3icyad7bccnkibl5wl
export ROOTSYS LD_LIBRARY_PATH=$ROOTSYS/lib/root:$VDT/lib:${LD_LIBRARY_PATH:-}
module load julia
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. edisplay.jl "$@"
