#!/usr/bin/env bash
set -euo pipefail

bzip2_exec="spec_alpha/bzip2/bzip2_base.alpha spec_alpha/bzip2/bzip2_input/input.source 280"
gcc_exec="spec_alpha/gcc/gcc.alpha spec_alpha/gcc/gcc_input/166.i -o spec_alpha/gcc/gcc_input/166.s"
gromacs_exec="spec_alpha/gromacs/gromacs_base.alpha -silent -deffnm spec_alpha/gromacs/gromacs_input/gromacs.tpr"
mcf_exec="spec_alpha/mcf/mcf_base.alpha spec_alpha/mcf/mcf_input/inp.in"

num_threads="${1:-0}"
config_file="${2:-example.cfg}"

if [ "$num_threads" -le 0 ]; then
  echo "usage: $0 <num_threads> <config_file> <w1> <w2> ... <wN>"
  echo "workloads: bzip2 | gcc | gromacs | mcf"
  exit 1
fi

# 인자 개수 확인: num_threads + 2(config_file 포함)
if [ "$#" -lt $((num_threads + 2)) ]; then
  echo "error: need $num_threads workload names after <num_threads> <config_file>"
  exit 1
fi

run_exec=""

# $3부터 num_threads개 읽기
for i in $(seq 1 "$num_threads"); do
  arg_idx=$((i + 2))
  eval "w=\${$arg_idx}"

  case "$w" in
    bzip2)   cmd="$bzip2_exec" ;;
    gcc)     cmd="$gcc_exec" ;;
    gromacs) cmd="$gromacs_exec" ;;
    mcf)     cmd="$mcf_exec" ;;
    *)
      echo "error: unknown workload '$w' (allowed: bzip2 gcc gromacs mcf)"
      exit 1
      ;;
  esac

  if [ -z "$run_exec" ]; then
    run_exec="$cmd"
  else
    run_exec="$run_exec -- $cmd"
  fi
done

echo "$run_exec"
./simplescalar/sim-outorder -config "./simplescalar/config/$config_file" $run_exec
