import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { commentOperation } from "../comments.js";
import { ANNOTATIONS } from "../annotations.js";

export function registerCommentTools(server: McpServer): void {
  const documentName = z.string().min(1).describe("Exact name of an open document");
  const text = z.string().min(1).max(20000).describe("Comment or reply text");
  const invoke = async (app: "Pages" | "Numbers", op: string, args: Record<string, unknown>) => {
    try { return { content: [{ type: "text" as const, text: JSON.stringify(await commentOperation(app,op,args),null,2) }] }; }
    catch (error) { return { content: [{ type: "text" as const, text: String(error) + " Requires macOS Automation and Accessibility access. Never automatically retry comment writes." }], isError: true }; }
  };
  for (const app of ["Pages", "Numbers"] as const) {
    const prefix = app.toLowerCase();
    server.tool(`${prefix}_list_comments`, "Read accessible comment text, author/date metadata, and reply availability. Pages opens the comments sidebar; Numbers reads the selected cell thread (optionally supply sheetName, tableName, and cell together). Reports incomplete scope rather than claiming all comments were read. Requires Accessibility access and English app UI.", { documentName, ...(app === "Numbers" ? { sheetName: z.string().min(1).optional(), tableName: z.string().min(1).optional(), cell: z.string().regex(/^[A-Z]+[1-9][0-9]*$/).optional() } : {}) }, ANNOTATIONS.readOnly, args => invoke(app,"list",args));
    server.tool(`${prefix}_reply_to_comment`, "Reply to exactly one comment matched by its full text from list_comments. Posting is verified; ambiguous matches fail. Never retry automatically after an error. Requires Accessibility access and English app UI.", { documentName, commentText: z.string().min(1), text }, ANNOTATIONS.readWrite, args => invoke(app,"reply",args));
  }
  server.tool("pages_add_comment", "Add a comment to a unique target passage in an accessible Pages body. Selects and verifies the exact passage before posting. Scroll target into view if needed. Requires Accessibility access and English app UI; never retry automatically.", { documentName, targetText: z.string().min(1), text }, ANNOTATIONS.readWrite, args => invoke("Pages","add",args));
  server.tool("numbers_add_comment", "Add a comment to a specified Numbers table cell. Selects its sheet/table/cell before posting. Requires Accessibility access and English app UI; never retry automatically.", { documentName, sheetName: z.string().min(1), tableName: z.string().min(1), cell: z.string().regex(/^[A-Z]+[1-9][0-9]*$/), text }, ANNOTATIONS.readWrite, args => invoke("Numbers","add",args));
}
