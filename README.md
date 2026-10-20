# Challenge Orange attempt

Julia / Pluto coursework implementation for the Orange ROADEF 2026 challenge.
The current implementation covers data preparation and the time-period-0 model,
using SCIP by default and HiGHS as an alternative. Later time periods and budget
constraints remain pending; see [CHECKLIST.md](CHECKLIST.md).

## Original material

- [Challenge subject](Challenge_Orange_ROADEF_2026_Subject.pdf)
- [Original coursework instructions](readme), preserved verbatim
- [Routing-ratio calculation handout](calculating_r.pdf)
- Lecturer-provided graph-reader notebooks: `json_to_graph_pluto_v2.jl`
  and `json_to_multigraph_pluto.jl`. These are reference material; the v2 copy
  includes local edits made during the coursework.
- `setA/`: supplied network, traffic-matrix, and scenario JSON instances.

Original teaching and challenge material remains attributed to its respective
authors. No additional license is asserted over that material.

## Install

Run from this repository root. The environment was last used with Julia 1.13.1;
`Manifest.toml` records package versions.

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Open the notebook

`Project_Orange.jl` contains the graph reader, Data section, mathematical model,
small executable examples, and experiment functions. To launch Pluto in a
separate environment:

```sh
julia -e 'using Pkg; Pkg.activate(joinpath(homedir(), ".julia", "environments", "orange-pluto")); Pkg.add("Pluto"); using Pluto; Pluto.run()'
```

Open `Project_Orange.jl` in Pluto. Its embedded package environment is included.
The long experiment batch is disabled by default.

## Run experiments

Start with a short trial:

```sh
julia --project=. scripts/run_experiments.jl --instances 1 --runs 1 --time-limit 30 --solver scip --output results/trial_lex_scip
```

Coursework time-0 settings (20 instances, ten repetitions, 1800 seconds per run):

```sh
julia --project=. scripts/run_experiments.jl --instances 1:20 --runs 10 --time-limit 1800 --solver scip --output results/time0_lex_scip
```

Use `--solver highs` and a separate output directory for a comparison.
These commands do not guarantee all instances can be solved: the explicit
model has a size guard, and large instances may be skipped before allocation.
The full batch can consume up to 100 hours of solver time.

The objective is the full lexicographic vector of decreasing normalized arc
loads, solved through sequential top-k objectives. An optimal maximum load
alone does not certify the full lexicographic optimum. Timing covers calls to
`optimize!` only. See [EXPERIMENTS.md](EXPERIMENTS.md) for status, gaps, logs,
resume behavior, and limitations; [DATA.md](DATA.md) explains input parameters.

Generated results and logs are ignored by Git. Existing exploratory pilot logs
are not distributed as benchmark results.

## Verify

```sh
julia --project=. test/runtests.jl
```

The data tests include exhaustive routing checks and may take longer than the
small model tests. The compatibility entry point `src/OrangeData.jl` includes
the notebook and therefore executes its small examples too.
