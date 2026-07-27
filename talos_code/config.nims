import std/[os, strutils]

switch("path", "src")

# nimble's own `build`/`c` command doesn't reliably inject --path for a
# git-url `requires` dependency the way exec-based tasks do (those fall
# back to Nim's default nimblePath lookup) — so find the installed
# talos_core package directory explicitly. Note: nimble flattens srcDir on
# install, so the package root itself (not root/src) is the right path.
let pkgs2 = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble") / "pkgs2"
if dirExists(pkgs2):
  for kind, path in walkDir(pkgs2):
    if kind == pcDir and path.extractFilename.startsWith("talos_core-"):
      switch("path", path)

switch("define", "ssl")