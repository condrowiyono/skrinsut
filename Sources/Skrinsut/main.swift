import AppKit

// `Skrinsut --mcp`: stdio MCP server for AI assistants. It never starts the UI; captures run in the app.
if CommandLine.arguments.contains("--mcp") { McpServer.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
