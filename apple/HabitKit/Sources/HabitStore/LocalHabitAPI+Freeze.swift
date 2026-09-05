import Foundation
import GRDB
import HabitCore

extension LocalHabitAPI {

    /// Alle Buchungen, die jüngste zuerst.
    public func freezeLedger() async throws -> [FreezeEntry] {
        try await dbQueue.read { [userId] db in
            try FreezeRow.fetchAll(db, sql: """
                SELECT * FROM freeze_ledger WHERE user_id = ? ORDER BY created_at DESC
                """, arguments: [userId]).map(\.entry)
        }
    }

    public func freezeBalance() async throws -> Int {
        HabitCore.freezeBalance(try await freezeLedger())
    }

    /// Bucht ein, was durchgezogene Läufe verdient haben.
    ///
    /// Idempotent über `focus_run_id`: derselbe Lauf zahlt genau einmal ein,
    /// egal wie oft dies aufgerufen wird. Deshalb darf es beim Nachladen
    /// mitlaufen — der Kontostand hinkt sonst hinterher, bis jemand zufällig
    /// den Fokus-Tab öffnet.
    ///
    /// Gibt die Zahl der neuen Buchungen zurück.
    @discardableResult
    public func awardPendingFreezes() async throws -> Int {
        let progress = try await focusProgress()
        let ledger = try await freezeLedger()
        let faellig = HabitCore.pendingFreezeAwards(
            outcomes: progress.map { (run: $0.run, outcome: $0.outcome) }, ledger: ledger)
        guard !faellig.isEmpty else { return 0 }

        try await dbQueue.write { [userId] db in
            for run in faellig {
                var row = FreezeRow(FreezeEntry(
                    userId: userId, amount: FreezeRule.perCompletedFocus,
                    reason: .focusCompleted, focusRunId: run.id))
                try row.insert(db)
            }
        }
        return faellig.count
    }

    /// Löst einen Freeze für einen verpassten Tag ein.
    ///
    /// Zwei Buchungen in einem Zug: die Ausnahme, die den Streak hält, und der
    /// Abzug vom Konto. Getrennt könnten sie auseinanderlaufen — ein geretteter
    /// Tag ohne Abzug wäre ein Freeze umsonst.
    @discardableResult
    public func applyFreeze(habitId: UUID, date: CalendarDate) async throws -> DayException {
        let today = currentDate()
        guard let habit = try await habit(id: habitId) else {
            throw HabitStoreError.habitNotFound(habitId)
        }
        guard try await freezeBalance() > 0 else {
            throw HabitStoreError.noFreezeAvailable
        }

        // Nur ein wirklich verpasster Tag. Ein erfüllter braucht keine Rettung,
        // und der laufende ist noch nicht verloren.
        let stats = try await stats(habitId: habitId, from: date, to: date)
        let status = stats.days[date] ?? .notScheduled
        guard HabitCore.canFreeze(status, on: date, today: today) else {
            throw HabitStoreError.dayNotFreezable(date: date, status: status.code)
        }

        let exception = DayException(habitId: habit.id, date: date, kind: .frozen,
                                     reason: "Streak Freeze")
        try await dbQueue.write { [userId] db in
            try Self.checkBackfill(date: date, today: today, db: db)
            var exceptionRow = DayExceptionRow(exception, userId: userId)
            try exceptionRow.insert(db)
            var ledgerRow = FreezeRow(FreezeEntry(
                userId: userId, amount: -1, reason: .applied,
                habitId: habitId, date: date))
            try ledgerRow.insert(db)
        }
        return exception
    }
}
