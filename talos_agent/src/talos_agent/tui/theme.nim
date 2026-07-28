## Talos TUI theme.
##
## Color palette and style configuration for the terminal UI.
## Default is a dark theme using the 16-color ANSI palette (works on every
## terminal). Configurable via `config.toml` key `[tui.theme]` in the
## future.

import illwill

type
  TuiTheme* = object
    userMsg*: ForegroundColor
    assistantMsg*: ForegroundColor
    toolCall*: ForegroundColor
    toolResult*: ForegroundColor
    errorMsg*: ForegroundColor
    statusBarFg*: ForegroundColor
    statusBarBg*: BackgroundColor
    inputPrompt*: ForegroundColor
    muted*: ForegroundColor
    accent*: ForegroundColor

proc defaultTheme*(): TuiTheme =
  TuiTheme(
    userMsg:       fgGreen,
    assistantMsg:  fgNone,
    toolCall:      fgYellow,
    toolResult:    fgCyan,
    errorMsg:      fgRed,
    statusBarFg:   fgBlack,
    statusBarBg:   bgWhite,
    inputPrompt:   fgCyan,
    muted:         fgBlue,
    accent:        fgMagenta,
  )

proc applyTheme*(tb: var TerminalBuffer; theme: TuiTheme; fg: ForegroundColor;
                 bright: bool = false) =
  tb.setForegroundColor(fg, bright)

proc applyStatusBar*(tb: var TerminalBuffer; theme: TuiTheme) =
  tb.setForegroundColor(theme.statusBarFg)
  tb.setBackgroundColor(theme.statusBarBg)