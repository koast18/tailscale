#!/usr/bin/env node
// 将 Resources/console.html 转成 C 字符串头文件（Sources/KPWebServer/ConsoleHTML.h）
// 用法: node Scripts/gen_console_asset.js <input.html> <output.h>
"use strict";
const fs = require("fs");

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error("usage: node gen_console_asset.js <input.html> <output.h>");
  process.exit(2);
}

let src = fs.readFileSync(inPath, "utf8");
// 转义：反斜杠、双引号、控制字符
let out = "";
for (const ch of src) {
  const code = ch.charCodeAt(0);
  if (ch === "\\") out += "\\\\";
  else if (ch === '"') out += '\\"';
  else if (ch === "\n") out += "\\n";
  else if (ch === "\r") out += "";
  else if (ch === "\t") out += "\\t";
  else if (code < 0x20) out += "\\x" + code.toString(16).padStart(2, "0");
  else out += ch;
}

const header = `// 自动生成，勿手改！由 Scripts/gen_console_asset.js 从 Resources/console.html 生成。
// 重新生成: node Scripts/gen_console_asset.js Resources/console.html Sources/KPWebServer/ConsoleHTML.h
static const char * const kKPConsoleHTML =
"${out}";
`;

fs.writeFileSync(outPath, header, "utf8");
console.log(`generated ${outPath} (${src.length} chars -> ${out.length} escaped)`);
