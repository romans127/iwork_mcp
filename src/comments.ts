import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { rename, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { setTimeout } from "node:timers/promises";
import { runJXA, resolveAppName } from "./jxa.js";
const exec = promisify(execFile);
const source = fileURLToPath(new URL("../assets/comments.swift", import.meta.url));
const binary = fileURLToPath(new URL("../dist/iwork-comments", import.meta.url));
let compiled: Promise<unknown> | undefined;
let pending: Promise<unknown> = Promise.resolve();
interface CommentRead { comments?: { messages?: string[] }[]; }
export function countCommentMessages(read: CommentRead, text: string): number {
  return (read.comments ?? []).flatMap(c => c.messages ?? []).filter(message => message === text).length;
}

/** Serialize UI writes and reads: selection and comment editors are app-global. */
export function commentOperation(app: "Pages" | "Numbers", operation: string, args: Record<string, unknown>): Promise<unknown> {
  const task = pending.then(async () => {
    const temporaryBinary = `${binary}.${process.pid}`;
    compiled ??= exec("/usr/bin/swiftc", [source, "-o", temporaryBinary], { timeout: 120000 })
      .then(() => rename(temporaryBinary,binary))
      .catch(async () => { compiled = undefined; await rm(temporaryBinary,{force:true}); throw new Error("Could not build native comment helper. Install Apple's Command Line Tools (swiftc)."); });
    await compiled;
    const document = await runJXA<{ documentName: string; bundleID: string }>(`
      const app = Application("${app}");
      const docs = app.documents().filter(d => d.name() === params.documentName || d.name() === params.documentName + (params.app === "Pages" ? ".pages" : ".numbers"));
      if (docs.length !== 1) throw Error("Expected exactly one matching open document");
      return JSON.stringify({ documentName: docs[0].name(), bundleID: app.id() });
    `, { ...args, app });
    const parameters = { ...args, ...document, appName: resolveAppName(app) };
    const invoke = async (op: string): Promise<Record<string, unknown> & CommentRead> => {
      try {
        const { stdout } = await exec(binary, [JSON.stringify({ ...parameters, operation: op })], { timeout: 60000, maxBuffer: 10 * 1024 * 1024 });
        return JSON.parse(stdout);
      } catch (error) {
        throw new Error((error as {stderr?: string}).stderr?.trim() || "Native comment helper failed or timed out; inspect the app before retrying.");
      }
    };
    const hasCellTarget = [args.sheetName, args.tableName, args.cell].some(value => value !== undefined);
    if (app === "Numbers" && hasCellTarget && ![args.sheetName, args.tableName, args.cell].every(value => typeof value === "string" && value.length > 0)) throw new Error("Supply sheetName, tableName, and cell together.");
    if (app === "Numbers" && (operation === "add" || (operation === "list" && hasCellTarget))) {
      // Check for drafts before selecting another cell, which could dismiss them.
      await invoke("prepare");
      await runJXA(`
        const app = Application("Numbers");
        const doc = app.documents.byName(params.documentName);
        const sheet = doc.sheets.byName(params.sheetName);
        const table = sheet.tables.byName(params.tableName);
        const range = table.ranges.byName(params.cell);
        range.name();
        doc.activeSheet = sheet;
        table.selectionRange = range;
        const selected = table.selectionRange.name();
        if (selected !== params.cell && selected !== params.cell + ":" + params.cell) throw Error("Cannot verify selected cell");
      `, { ...args, documentName: document.documentName });
    }
    const result = await invoke(operation);
    if (!result.submitted) return result;
    // A fresh native process avoids stale AX references after a popover closes.
    // Only re-read here; never retry the mutation.
    for (let attempt = 0; attempt < 3; attempt++) {
      await setTimeout(200);
      const read = await invoke("list");
      if (countCommentMessages(read, String(args.text)) > Number(result.beforeCount)) {
        return { documentName: document.documentName, posted: true, text: args.text, comments: read.comments };
      }
    }
    throw new Error("Submission attempted but could not be verified. Inspect comments before retrying.");
  });
  pending = task.catch(() => undefined);
  return task;
}
