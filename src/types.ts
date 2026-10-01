export type MatchLevel = "HIGH" | "MEDIUM" | "LOW";

export interface JobInfo {
  title: string;
  company: string;
  location: string;
}

export interface MatchAnalysis {
  match_score: number;
  match_level: MatchLevel;
  key_matching_skills: string[];
  missing_requirements: string[];
  match_reason: string;
}

export interface ApplicationMaterials {
  tailored_summary: string;
  cover_letter: string;
}

export interface CareerAnalysisResult {
  job_info: JobInfo;
  match_analysis: MatchAnalysis;
  application_materials: ApplicationMaterials;
}

export interface JobPosting {
  title: string;
  company: string;
  location: string;
  description: string;
}
