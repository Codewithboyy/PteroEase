#!/usr/bin/env node
import { pbkdf2Sync, randomBytes } from "node:crypto";
import { stdin, stdout } from "node:process";

const email = (process.argv[2] || "").trim().toLowerCase();
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
  console.error("Usage: node scripts/hash-password.mjs approved-admin@example.com");
  process.exit(2);
}

function readHidden(prompt) {
  return new Promise((resolve, reject) => {
    if (!stdin.isTTY || typeof stdin.setRawMode !== "function") {
      reject(new Error("Run this command in an interactive terminal."));
      return;
    }
    stdout.write(prompt);
    let value = "";
    const onData = chunk => {
      const s = chunk.toString("utf8");
      for (const ch of s) {
        if (ch === "\u0003") { cleanup(); reject(new Error("Cancelled")); return; }
        if (ch === "\r" || ch === "\n") { cleanup(); stdout.write("\n"); resolve(value); return; }
        if (ch === "\u007f" || ch === "\b") value = value.slice(0, -1);
        else if (ch >= " " && ch !== "\u007f") value += ch;
      }
    };
    const cleanup = () => {
      stdin.off("data", onData);
      stdin.setRawMode(false);
      stdin.pause();
    };
    stdin.setRawMode(true);
    stdin.resume();
    stdin.on("data", onData);
  });
}

try {
  const password = await readHidden("Choose a strong password (12+ characters): ");
  const confirm = await readHidden("Confirm password: ");
  if (password.length < 12 || password.length > 256) throw new Error("Password must be 12–256 characters.");
  if (password !== confirm) throw new Error("Passwords do not match.");
  const iterations = 210000;
  const salt = randomBytes(16);
  const derived = pbkdf2Sync(password, salt, iterations, 32, "sha256");
  const b64url = b => b.toString("base64url");
  const hash = `pbkdf2$${iterations}$${b64url(salt)}$${b64url(derived)}`;
  const id = randomBytes(16).toString("hex");
  const now = Math.floor(Date.now() / 1000);
  const esc = s => s.replaceAll("'", "''");
  console.log("\nPaste this SQL into the Cloudflare D1 console. It contains a password HASH, not the password:\n");
  console.log(`INSERT INTO users (id, email, password_hash, role, approved, created_at) VALUES ('${id}', '${esc(email)}', '${hash}', 'admin', 1, ${now});`);
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
