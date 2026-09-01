// Fixture for the gate self-test: must be clean under every phase.
// selftest.ps1 injects violations into a temp copy of this file.
package main

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() { _ = Add(1, 2) }
