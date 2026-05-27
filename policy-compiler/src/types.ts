import { z } from "zod";

export const PolicyAction = z.enum(["log", "blur", "block"]);
export type PolicyAction = z.infer<typeof PolicyAction>;

/// Plain JSON-schema literal used with `output_config.format`. The Anthropic
/// structured-outputs feature does NOT support numerical constraints, string
/// constraints, or complex array constraints, so the schema is intentionally
/// thin — the system prompt enforces caption counts, threshold ranges, and
/// the snake_case id rule. We keep the Zod schema below for downstream
/// runtime validation in TypeScript callers.
export const POLICY_JSON_SCHEMA = {
  type: "object",
  properties: {
    categories: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          description: { type: "string" },
          positive_captions: { type: "array", items: { type: "string" } },
          negative_captions: { type: "array", items: { type: "string" } },
          threshold: { type: "number" },
          threshold_note: { type: "string" },
          action: { type: "string", enum: ["log", "blur", "block"] },
        },
        required: [
          "id",
          "description",
          "positive_captions",
          "negative_captions",
          "threshold",
          "threshold_note",
          "action",
        ],
        additionalProperties: false,
      },
    },
    clarifications: { type: "array", items: { type: "string" } },
    calibration_note: { type: "string" },
  },
  required: ["categories", "clarifications", "calibration_note"],
  additionalProperties: false,
} as const;

export const PolicyCategory = z.object({
  id: z
    .string()
    .regex(/^[a-z][a-z0-9_]*$/, "snake_case, lowercase, starts with letter"),
  description: z.string().min(1),
  positive_captions: z
    .array(z.string().min(1))
    .min(6)
    .max(14)
    .describe("Captions describing the UNSAFE class. 8-12 typical."),
  negative_captions: z
    .array(z.string().min(1))
    .min(6)
    .max(14)
    .describe("Captions describing the SAFE class. 8-12 typical."),
  threshold: z
    .number()
    .min(0)
    .max(1)
    .describe("Cosine-similarity threshold for triggering the action."),
  threshold_note: z.string().min(1),
  action: PolicyAction,
});
export type PolicyCategory = z.infer<typeof PolicyCategory>;

export const Policy = z.object({
  categories: z.array(PolicyCategory).min(1).max(20),
  clarifications: z.array(z.string()),
  calibration_note: z.string(),
});
export type Policy = z.infer<typeof Policy>;

export const DeploymentMode = z.enum(["personal", "corporate"]);
export type DeploymentMode = z.infer<typeof DeploymentMode>;
