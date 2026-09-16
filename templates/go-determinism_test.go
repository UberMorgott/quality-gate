// Property tests for a deterministic package (quality-gate#48). Copy next to the
// package, rename the package clause, and replace State/NewState/Step/Snapshot/Restore
// with the real simulation API. Needs: go get pgregory.net/rapid
//
// The two properties every replayable simulation has to keep:
//  1. same seed + same inputs -> same trace (no clock, rand, map order or goroutines leak in);
//  2. Restore(Snapshot(s)) continues exactly like s would have.
//
// On failure rapid prints the minimal input; re-run with -rapid.failfile=<file> to replay.
package sim

import (
	"reflect"
	"testing"

	"pgregory.net/rapid"
)

func TestSameInputSameTrace(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		seed := rapid.Uint64().Draw(t, "seed")
		inputs := rapid.SliceOf(rapid.IntRange(0, 16)).Draw(t, "inputs")

		trace := func() []State {
			s := NewState(seed)
			out := make([]State, 0, len(inputs))
			for _, in := range inputs {
				s = Step(s, in)
				out = append(out, s)
			}
			return out
		}
		if a, b := trace(), trace(); !reflect.DeepEqual(a, b) {
			t.Fatalf("two runs diverged:\n%v\n%v", a, b)
		}
	})
}

func TestRestoreSnapshotContinuesIdentically(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		s := NewState(rapid.Uint64().Draw(t, "seed"))
		for _, in := range rapid.SliceOf(rapid.IntRange(0, 16)).Draw(t, "prefix") {
			s = Step(s, in)
		}
		restored := Restore(Snapshot(s))
		if !reflect.DeepEqual(restored, s) {
			t.Fatalf("restore(snapshot(s)) != s:\n%v\n%v", restored, s)
		}
		for _, in := range rapid.SliceOf(rapid.IntRange(0, 16)).Draw(t, "suffix") {
			s, restored = Step(s, in), Step(restored, in)
		}
		if !reflect.DeepEqual(restored, s) {
			t.Fatalf("restored state diverged after replay:\n%v\n%v", restored, s)
		}
	})
}
