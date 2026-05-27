import { z } from "zod";

export const PolicyAction = z.enum(["log", "blur", "block"]);
export type PolicyAction = z.infer<typeof PolicyAction>;

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
