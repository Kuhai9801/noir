#!/usr/bin/env bash
set -u

ROOT="$(pwd)"
NARGO="${NARGO:-nargo}"
LOG_DIR="$ROOT/repro-logs"
WORK_DIR="$ROOT/repro-work"

rm -rf "$LOG_DIR" "$WORK_DIR"
mkdir -p "$LOG_DIR" "$WORK_DIR"

run_case() {
  local name="$1"
  shift
  echo "== $name =="
  set +e
  "$@" >"$LOG_DIR/$name.log" 2>&1
  local code=$?
  set -e
  echo "$code" >"$LOG_DIR/$name.exit"
  cat "$LOG_DIR/$name.log"
  echo
  return 0
}

make_pkg() {
  local name="$1"
  mkdir -p "$WORK_DIR/$name/src"
  cat >"$WORK_DIR/$name/Nargo.toml" <<EOF
[package]
name = "$name"
type = "bin"
authors = [""]
compiler_version = ">=1.0.0"
EOF
}

download_latest_nargo_if_missing() {
  if command -v "$NARGO" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x "$ROOT/.nargo/bin/nargo" ]]; then
    NARGO="$ROOT/.nargo/bin/nargo"
    return 0
  fi

  mkdir -p "$ROOT/.nargo"
  local url
  url="$(curl -fsSL https://api.github.com/repos/noir-lang/noir/releases/latest \
    | jq -r '.assets[] | select(.name=="nargo-x86_64-unknown-linux-gnu.tar.gz") | .browser_download_url')"
  curl -fsSL "$url" -o "$ROOT/.nargo/nargo.tar.gz"
  tar -xzf "$ROOT/.nargo/nargo.tar.gz" -C "$ROOT/.nargo"
  NARGO="$(find "$ROOT/.nargo" -maxdepth 2 -type f -name nargo | head -n1)"
  chmod +x "$NARGO"
}

download_latest_nargo_if_missing
"$NARGO" --version | tee "$LOG_DIR/nargo-version.txt"

# 1. Cache validation profile. Reproduced if:
# clean default/force rejects, skip compile succeeds, default after skip succeeds,
# and force after skip rejects.
make_pkg cache_validation
cat >"$WORK_DIR/cache_validation/src/main.nr" <<'NR'
unconstrained fn plus_one(x: Field) -> Field {
    x + 1
}

fn main(x: Field) -> pub Field {
    let y = unsafe { plus_one(x) };
    y
}
NR
pushd "$WORK_DIR/cache_validation" >/dev/null
run_case cache_clean_default "$NARGO" compile --force
run_case cache_skip "$NARGO" compile --skip-brillig-constraints-check --skip-underconstrained-check
run_case cache_default_after_skip "$NARGO" compile
run_case cache_force_after_skip "$NARGO" compile --force
popd >/dev/null

# 2. Cast composition. Reproduced if this execution fails the z == 255 assert.
make_pkg cast_composition
cat >"$WORK_DIR/cast_composition/src/main.nr" <<'NR'
fn main(x: i8) -> pub i16 {
    assert(x == -1);
    let y: u8 = x as u8;
    let z: i16 = y as i16;
    assert(z == 255);
    z
}
NR
cat >"$WORK_DIR/cast_composition/Prover.toml" <<'TOML'
x = -1
TOML
pushd "$WORK_DIR/cast_composition" >/dev/null
run_case cast_execute "$NARGO" execute
popd >/dev/null

# 3. Mutable array-set aliasing. Reproduced if value semantics are broken and
# the v4[0][0] == 0 assert fails after optimization/execution.
make_pkg mutable_array_set_alias
cat >"$WORK_DIR/mutable_array_set_alias/src/main.nr" <<'NR'
fn main() {
    let mut v2 = [5];
    v2[0] = 0;

    let v3 = [9];
    let mut v4 = [v3];
    v4[0] = v2;

    v2[0] = 7;

    assert(v4[0][0] == 0);
    assert(v2[0] == 7);
}
NR
pushd "$WORK_DIR/mutable_array_set_alias" >/dev/null
run_case mutable_array_execute "$NARGO" execute
popd >/dev/null

# 4. Brillig vector stale MakeArray cache. Reproduced if the fresh vector reads
# from storage mutated by push_front and the got == 1 assert fails.
make_pkg vector_intrinsic_cache
cat >"$WORK_DIR/vector_intrinsic_cache/src/main.nr" <<'NR'
unconstrained fn fresh_after_push_front() -> Field {
    let base: [Field] = @[1, 2, 3];
    let shifted = base.push_front(0);
    assert(shifted[0] == 0);

    let fresh: [Field] = @[1, 2, 3];
    fresh[0]
}

fn main() -> pub Field {
    let got = unsafe { fresh_after_push_front() };
    assert(got == 1);
    got
}
NR
pushd "$WORK_DIR/vector_intrinsic_cache" >/dev/null
run_case vector_execute "$NARGO" execute
popd >/dev/null

{
  echo "# Noir principal repro summary"
  echo
  echo "| Case | Exit code |"
  echo "|---|---:|"
  for f in "$LOG_DIR"/*.exit; do
    echo "| $(basename "$f" .exit) | $(cat "$f") |"
  done
} | tee "$LOG_DIR/summary.md"

echo "Logs written to $LOG_DIR"
