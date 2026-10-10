/**
 * Level 2, option B: resume screening.
 * Not rate this resume. Atomic questions: distributed systems? seniority? fit? Each answer is a signal the code combines.
 */
import { jev } from "../../core/client.ts";
import { noul, score } from "../../core/helpers.ts";
import type { NoulAnswer, ScoreAnswer } from "../../core/types.ts";

export interface ResumeVerdict {
  proceed: boolean;
  signals: { distributed: boolean; senior: boolean; fitScore: number };
}

/** B: resume screening as atomic questions, not one giant "rate this resume". */
export async function screenResume(resume: string, jobDescription: string): Promise<ResumeVerdict> {
  const { answers } = await jev.systemOne({ resume, job_description: jobDescription }, {
    mentions_distributed: noul("Does `resume` state the candidate used distributed systems at work?"),
    seniority: score("How senior does the candidate in `resume` appear for the role in `job_description`?", [
      "Junior; guided work, limited ownership",
      "Mid-level; owns features end to end",
      "Senior; owns systems, sets direction, mentors others",
    ]),
    job_fit: score("How well does `resume` match the requirements in `job_description`?", [
      "Few requirements are met",
      "Core requirements are met",
      "Requirements are met with directly relevant experience",
    ]),
  });
  const signals = {
    distributed: (answers.mentions_distributed as NoulAnswer).noul > 0.5,
    senior: (answers.seniority as ScoreAnswer).score >= 1.5,
    fitScore: (answers.job_fit as ScoreAnswer).score,
  };
  return { proceed: signals.fitScore > 1.0 && signals.senior, signals };
}
