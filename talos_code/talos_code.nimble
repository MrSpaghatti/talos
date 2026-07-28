version       = "0.1.0"
author        = "Talos"
description   = "Talos coding harness — autonomous coding assistant"
license       = "MIT"
srcDir        = "src"
bin           = @["talos_code"]
requires      "nim >= 2.0.0"
requires      "https://github.com/mrspaghatti/talos_core#v1.5.0"
switch("path", "src")

task test, "Run tests":
  exec "nim c --path:src -r tests/tcode_runner.nim"