// Command gopurity reports the constructs of a deterministic Go package that
// forbidigo and depguard cannot express (quality-gate#46): range over a map
// (randomized iteration order), go statements and select statements. Stdlib only,
// so `go run` needs no network: the qgate purity profile runs it per listed package.
//
// Usage: go run main.go <package dir>...   Output: file:line:col: message, exit 0.
// A package that does not type-check is still scanned; a map whose type is unknown
// (a broken import) is not reported.
package main

import (
	"fmt"
	"go/ast"
	"go/build"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
)

func main() {
	fset := token.NewFileSet()
	imp := importer.ForCompiler(fset, "source", nil)
	for _, dir := range os.Args[1:] {
		bp, err := build.ImportDir(dir, 0)
		if err != nil {
			fmt.Fprintf(os.Stderr, "gopurity: %s: %v\n", dir, err)
			continue
		}
		var files []*ast.File
		for _, name := range append(bp.GoFiles, bp.CgoFiles...) {
			f, err := parser.ParseFile(fset, filepath.Join(dir, name), nil, 0)
			if err != nil {
				fmt.Fprintf(os.Stderr, "gopurity: %v\n", err)
				continue
			}
			files = append(files, f)
		}
		info := &types.Info{Types: map[ast.Expr]types.TypeAndValue{}}
		conf := types.Config{Importer: imp, Error: func(error) {}}
		_, _ = conf.Check(bp.ImportPath, fset, files, info)
		for _, f := range files {
			ast.Inspect(f, func(n ast.Node) bool {
				msg := ""
				switch s := n.(type) {
				case *ast.RangeStmt:
					if t := info.TypeOf(s.X); t != nil {
						if _, ok := t.Underlying().(*types.Map); ok {
							msg = "range over map: iteration order is random -- sort the keys first"
						}
					}
				case *ast.GoStmt:
					msg = "go statement: goroutine scheduling is not deterministic"
				case *ast.SelectStmt:
					msg = "select statement: case choice is random"
				}
				if msg != "" {
					fmt.Printf("%s: %s (gopurity)\n", fset.Position(n.Pos()), msg)
				}
				return true
			})
		}
	}
}
