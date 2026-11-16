# Pages and Numbers comments (Romans127 fork)

This fork adds six tools: `pages_list_comments`, `pages_add_comment`,
`pages_reply_to_comment`, `numbers_list_comments`, `numbers_add_comment`, and
`numbers_reply_to_comment`.

These tools control the native app through macOS Accessibility because Apple's
scripting dictionary does not expose comment objects. The native helper is compiled locally on first use with Apple’s Command Line Tools (`swiftc`). They require Automation
and Accessibility permissions for the hosting application and an English app UI.
They bring the named document to the front and may open its comment sidebar.
Do not use the keyboard or change documents while a comment call is running.

Pages additions take `documentName`, `targetText`, and `text`. The passage must
be unique within its accessible body text area; scroll it into view first.
Numbers additions take `documentName`, `sheetName`, `tableName`, `cell` (A1),
and `text`. Replies take `documentName`, `commentText` (exact full text returned
by a fresh list call), and `text`. Identical matching comments are rejected.

Numbers reads the selected cell’s comment thread. To review another cell, pass `sheetName`, `tableName`, and `cell` together to `numbers_list_comments`. It does not scan the whole workbook.

List responses return text, accessibility descriptions, metadata, and whether a
reply control exists. `complete: false` is intentional: hidden, filtered,
collapsed, or unloaded threads may be missing. Do not claim a complete document
review based only on these results. Thread metadata follows the app's accessible
presentation; timestamps can be relative. Resolved comments and track changes
are not supported.

Writes are serialized within this server process. Existing comment drafts,
ambiguous passages, changed foreground windows, and unavailable controls cause
an error. Posting must be observed in the comment pane before success is
returned. An error after submission may mean the comment was posted: list
comments and inspect the app before retrying. Calls can be slow on large files.

The fork is installed locally with:

```json
{"command":"node","args":["/Volumes/ext_shield/code/mcp-servers/iwork_mcp/dist/index.js"]}
```

Rebuild with `npm run build` after updating the clone. Restart the MCP client to
refresh its tool list.
