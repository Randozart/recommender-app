#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
out=$(mktemp -d /tmp/briev-profile-admission.XXXXXX)
trap 'rm -rf "$out"' EXIT
"$BV" build tests/fixtures/recommender/profile_admission_gate.bv --out "$out"
PROFILE_ADMISSION_TEST_EPOCH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$out/profile_admission_gate"
