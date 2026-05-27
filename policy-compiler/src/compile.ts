#!/usr/bin/env node
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import fs from "node:fs";
import path from "node:path";
import { Policy, DeploymentMode } from "./types.js";
import { POLICY_COMPILER_SYSTEM_PROMPT, userMessage } from "./prompt.js";

const USAGE = `Usage: valueguard-compile <values.md> [personal|corporate]

Compiles a plain-English values statement into a SigLIP-2-ready
policy.json. Writes <values>.policy.json alongside the input file.

Reads ANTHROPIC_API_KEY from the environment.`;

const [valuesPath, modeArg = "personal"] = process.argv.slice(2);

if (!valuesPath) {
  console.error(USAGE);
  process.exit(1);
}
if (!fs.existsSync(valuesPath)) {
  console.error(`error: values file not found: ${valuesPath}`);
  process.exit(1);
}

const modeParse = DeploymentMode.safeParse(modeArg);
if (!modeParse.success) {
  console.error(`error: mode must be "personal" or "corporate", got "${modeArg}"`);
  process.exit(1);
}
const mode = modeParse.data;

const values = fs.readFileSync(valuesPath, "utf-8").trim();
if (!values) {
  console.error("error: values file is empty");
  process.exit(1);
}

const client = new Anthropic();

console.error(`Compiling policy from ${valuesPath} (mode: ${mode})...`);
console.error("Sending values statement to Sonnet. No screen data leaves this machine.");

const response = await client.messages.parse({
  model: "claude-sonnet-4-6",
  max_tokens: 8192,
  thinking: { type: "adaptive" },
  output_config: { format: zodOutputFormat(Policy) },
  system: POLICY_COMPILER_SYSTEM_PROMPT,
  messages: [{ role: "user", content: userMessage(values, mode) }],
});

if (!response.parsed_output) {
  console.error("error: model returned no structured output");
  console.error("stop_reason:", response.stop_reason);
  if (response.stop_reason === "refusal" && response.stop_details) {
    console.error("refusal details:", response.stop_details);
  }
  process.exit(2);
}

const policy = response.parsed_output;

const outPath = valuesPath.endsWith(".md")
  ? valuesPath.replace(/\.md$/, ".policy.json")
  : `${valuesPath}.policy.json`;

fs.writeFileSync(outPath, JSON.stringify(policy, null, 2) + "\n");

console.error("");
console.error(`Wrote ${outPath}`);
console.error(`  ${policy.categories.length} categor${policy.categories.length === 1 ? "y" : "ies"}:`);
for (const cat of policy.categories) {
  console.error(
    `    - ${cat.id} (threshold=${cat.threshold.toFixed(2)}, action=${cat.action}, ${cat.positive_captions.length}+${cat.negative_captions.length} captions)`,
  );
}
if (policy.clarifications.length > 0) {
  console.error("");
  console.error(`  ${policy.clarifications.length} clarification${policy.clarifications.length === 1 ? "" : "s"} the model wants answered:`);
  for (const q of policy.clarifications) {
    console.error(`    - ${q}`);
  }
}

console.error("");
console.error("Token usage:");
console.error(`  input:  ${response.usage.input_tokens}`);
console.error(`  output: ${response.usage.output_tokens}`);

console.error("");
console.error("Next step:");
console.error(`  cd ../model-conversion && python embed_captions.py ${path.relative(process.cwd(), outPath)}`);
