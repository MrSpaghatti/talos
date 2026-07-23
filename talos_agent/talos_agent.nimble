version       = "0.1.0"
author        = "Talos"
description   = "Talos agent binary"
license       = "MIT"
srcDir        = "src"
bin           = @["talos_agent"]
requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0"
requires "illwill >= 0.4.0"
requires "dimscord >= 1.0.0"
requires "cligen >= 1.6.0"
switch("path", "src")
switch("path", "../talos_core/src")
switch("path", "../talos_core/tests")

task test, "Run all tests":
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests --threads:on -r tests/tagent_loop.nim"
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests -r tests/tcli.nim"
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests -r tests/test_shell_tool.nim"
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests --threads:on -r tests/tintegration.nim"
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests -r tests/tdelegate_tool.nim"
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests -r tests/tbench.nim"
  exec "nim c --path:src --path:../talos_core/src --path:../talos_core/tests --threads:on -r tests/tweb_server.nim"
