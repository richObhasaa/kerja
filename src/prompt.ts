import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { JobPosting } from "./types.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const TEMPLATE_PATH = join(__dirname, "..", "templates", "career_intelligence_engine.txt");

export function buildPrompt(cvText: string, job: JobPosting): string {
  const template = readFileSync(TEMPLATE_PATH, "utf-8");
  return template
    .replaceAll("{{CV_TEXT}}", cvText.trim())
    .replaceAll("{{JOB_TITLE}}", job.title.trim())
    .replaceAll("{{COMPANY_NAME}}", job.company.trim())
    .replaceAll("{{JOB_LOCATION}}", job.location.trim())
    .replaceAll("{{JOB_DESCRIPTION}}", job.description.trim());
}
