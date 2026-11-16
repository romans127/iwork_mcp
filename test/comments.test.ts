import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { createTestServer, type TestContext } from "./helpers/server.js";

describe("Comment tool contracts", () => {
  let ctx: TestContext;
  before(async () => { ctx = await createTestServer(); });
  after(async () => { await ctx.cleanup(); });
  it("registers six comment tools with appropriate annotations", async () => {
    const { tools } = await ctx.client.listTools();
    const comments = tools.filter(t => /_(list_comments|add_comment|reply_to_comment)$/.test(t.name));
    assert.equal(comments.length, 6);
    for (const tool of comments) {
      assert.equal(tool.annotations?.readOnlyHint, tool.name.endsWith("list_comments"));
      assert.equal(tool.annotations?.destructiveHint, false);
    }
  });
  it("rejects ambiguous or missing anchors before opening an editor", async () => {
    for (const [name, args] of [
      ["pages_add_comment", { documentName: "test", text: "note", targetText: "" }],
      ["numbers_add_comment", { documentName: "test", sheetName: "Sheet 1", tableName: "Table 1", cell: "A0", text: "note" }],
      ["pages_reply_to_comment", { documentName: "test", commentText: "", text: "reply" }],
    ] as const) {
      const result = await ctx.client.callTool({ name, arguments: args });
      assert.equal(result.isError, true);
      assert.match(JSON.stringify(result.content), /validation|invalid|too_small/i);
    }
  });
});

describe("Posted comment verification", () => {
  it("counts whole messages without confusing substrings or multiline text", async () => {
    const { countCommentMessages } = await import("../src/comments.js");
    const read = { comments: [
      { messages: ["A note", "A note with extra words", "First line\nSecond line"] },
      { messages: ["A note"] },
    ] };
    assert.equal(countCommentMessages(read,"A note"),2);
    assert.equal(countCommentMessages(read,"First line\nSecond line"),1);
    assert.equal(countCommentMessages(read,"First line"),0);
    assert.equal(countCommentMessages({},"A note"),0);
  });
});
