import Foundation

extension JobRunResult {
    /// The result of a job run a front end carried out itself: it evaluated the job, showed the plan, got the
    /// person's go-ahead and executed exactly that plan. Pass it to `JobRunner.record` so the job's state moves on
    /// as it does for `JobRunner.run`. `report` is `nil` when the job had nothing to do.
    public static func manual(_ evaluation: JobEvaluation, report: CleanupReport?, date: Date = Date()) -> JobRunResult {
        let action: Action = report.map { .cleaned($0) } ?? .notTriggered(evaluation.triggerSummary)
        return JobRunResult(job: evaluation.job, date: date, evaluation: evaluation, action: action)
    }
}
