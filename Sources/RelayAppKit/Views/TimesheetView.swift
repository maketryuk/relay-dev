import RelayTracker
import RelayUI
import SwiftUI

/// The time you recorded, on any issue, laid out by day: a week of columns or
/// a month of days, the way the tracker's own timesheet lays it out.
///
/// Every entry here is yours, so every one can be corrected where it stands;
/// the issue it was recorded on opens from its key.
struct TimesheetView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var span: Timesheet.Span = .week
    /// Any day of the week or month on screen.
    @State private var day = Date()

    private var tracker: TrackerController { model.tracker }
    private var calendar: Calendar { .current }
    private var locale: Locale { Localization.shared.locale }

    var body: some View {
        let days = Timesheet.days(
            span,
            around: day,
            entries: Array(tracker.timeEntries.values),
            schedule: tracker.workSchedule ?? .standard,
            in: calendar
        )
        let shown = Timesheet.shown(span, around: day, in: calendar)
        VStack(spacing: 0) {
            toolbar(days)
            RelayDivider()
            switch span {
            case .week:
                WeekColumns(project: project, days: days)
            case .month:
                MonthGrid(project: project, days: days) { chosen in
                    day = chosen
                    span = .week
                }
            }
        }
        .task(id: "\(span.rawValue)@\(shown.first.timeIntervalSince1970)") {
            tracker.readTime(from: shown.first, through: shown.last, in: calendar)
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ days: [Timesheet.Day]) -> some View {
        let totals = Timesheet.totals(of: days)
        return HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let failure = tracker.timeFailure {
                    Text(verbatim: TrackerText.describe(failure))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.statusError)
                        .lineLimit(2)
                } else {
                    Text(verbatim: String(
                        format: relayLocalized("Spent %@ of %@"),
                        TrackerText.duration(minutes: totals.minutes),
                        TrackerText.duration(minutes: totals.expected)
                    ))
                    .font(Theme.Typography.rowSecondary)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            IconButton(systemImage: "chevron.left", size: Theme.Metrics.action + 2) {
                day = Timesheet.moving(day, by: -1, span, in: calendar)
            }
            .relayTooltip(relayLocalized("Earlier"))
            RelayButton(relayLocalized("Today")) { day = Date() }
            IconButton(systemImage: "chevron.right", size: Theme.Metrics.action + 2) {
                day = Timesheet.moving(day, by: 1, span, in: calendar)
            }
            .relayTooltip(relayLocalized("Later"))

            RelayDateField(date: $day)
                .frame(width: 170)

            RelayTabs(Timesheet.Span.allCases, selection: $span, title: spanTitle)

            IconButton(systemImage: "arrow.clockwise", size: Theme.Metrics.action + 2, isBusy: tracker.isReadingTime) {
                let shown = Timesheet.shown(span, around: day, in: calendar)
                tracker.readTime(from: shown.first, through: shown.last, in: calendar)
            }
            .relayTooltip(relayLocalized("Reload the time"))
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private func spanTitle(_ span: Timesheet.Span) -> String {
        switch span {
        case .week: relayLocalized("Week")
        case .month: relayLocalized("Month")
        }
    }

    /// `28 сентября – 4 октября 2026 г.`, or `Сентябрь 2026 г.`, in the
    /// window's language.
    private var title: String {
        let period = Timesheet.period(span, around: day, in: calendar)
        switch span {
        case .week:
            let style = Date.IntervalFormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar)
            return (period.first ..< period.last).formatted(style)
        case .month:
            let month = period.first.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide).year())
            return month.prefix(1).uppercased() + month.dropFirst()
        }
    }
}

// MARK: - A week

/// Seven columns, a day each, with what was recorded on it as cards.
private struct WeekColumns: View {
    let project: Project
    let days: [Timesheet.Day]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Palette.border)
                        .frame(width: 1)
                }
                DayColumn(project: project, day: day)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DayColumn: View {
    let project: Project
    let day: Timesheet.Day

    private var isToday: Bool { Calendar.current.isDateInToday(day.start) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(verbatim: TimesheetText.weekday(day.start))
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(isToday ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                Text(verbatim: "\(Calendar.current.component(.day, from: day.start))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: Theme.Spacing.xsmall)
                DayTotal(day: day)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.small)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(day.entries) { entry in
                        TimeEntryCard(project: project, entry: entry)
                    }
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.bottom, Theme.Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TimesheetText.background(of: day, isToday: isToday))
    }
}

/// One entry: the issue, how long, what about and what kind of work. A click
/// corrects it; the key opens the issue.
private struct TimeEntryCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let entry: TrackerTimeEntry

    @State private var isHovering = false
    @State private var isConfirmingDeletion = false

    /// The whole of it, for the tooltip. The system's own rather than Relay's:
    /// a week of cards reporting where they are on every frame of a scroll is
    /// the scroll.
    private var whole: String {
        [entry.summary, entry.item.type?.name, entry.item.text.isEmpty ? nil : entry.item.text]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xsmall) {
                Button {
                    model.openIssue(entry.issueKey, in: project.id)
                } label: {
                    Text(verbatim: entry.issueKey)
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.accent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .clickable()

                Spacer(minLength: Theme.Spacing.xsmall)

                Badge(TrackerText.duration(minutes: entry.item.minutes), tint: Theme.Palette.textSecondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            if !entry.summary.isEmpty {
                Text(verbatim: entry.summary)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
            }
            if let type = entry.item.type {
                Text(verbatim: type.name)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { edit() }
        .clickable()
        .help(whole)
        .contextMenu {
            Button(relayLocalized("Open Issue")) { model.openIssue(entry.issueKey, in: project.id) }
            Divider()
            Button(relayLocalized("Edit…")) { edit() }
            Button(relayLocalized("Delete…")) { isConfirmingDeletion = true }
        }
        .confirmationDialog(relayLocalized("Delete this time?"), isPresented: $isConfirmingDeletion) {
            Button(relayLocalized("Delete"), role: .destructive) {
                Task { _ = await model.tracker.deleteWork(entry.item, on: entry.issueKey) }
            }
            Button(relayLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: String(
                format: relayLocalized("%@ logged on %@ is taken off %@."),
                TrackerText.duration(minutes: entry.item.minutes),
                TrackerText.day(entry.item.date),
                entry.issueKey
            ))
        }
    }

    private func edit() {
        model.presentModal(.editWork(key: entry.issueKey, itemID: entry.id))
    }
}

// MARK: - A month

/// Every week the month touches, a day to a cell, each saying what it came to
/// and what it was spent on. A day opens as its week.
private struct MonthGrid: View {
    let project: Project
    let days: [Timesheet.Day]
    let onChoose: (Date) -> Void

    /// As many as a cell has room for at the size the panel opens at; the
    /// rest are counted.
    private static let entriesPerCell = 4

    private var weeks: [[Timesheet.Day]] {
        stride(from: 0, to: days.count, by: 7).map { Array(days[$0 ..< min($0 + 7, days.count)]) }
    }

    var body: some View {
        let weeks = weeks
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weeks.first ?? []) { day in
                    Text(verbatim: TimesheetText.weekday(day.start))
                        .font(Theme.Typography.sectionHeader)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.small)
                }
            }
            ForEach(weeks.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(weeks[row]) { day in
                        cell(day)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ day: Timesheet.Day) -> some View {
        let isToday = Calendar.current.isDateInToday(day.start)
        return Button { onChoose(day.start) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(verbatim: "\(Calendar.current.component(.day, from: day.start))")
                        .font(Theme.Typography.row)
                        .foregroundStyle(isToday ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    Spacer(minLength: Theme.Spacing.xsmall)
                    DayTotal(day: day)
                }
                ForEach(day.entries.prefix(Self.entriesPerCell)) { entry in
                    HStack(spacing: Theme.Spacing.xsmall) {
                        Text(verbatim: entry.issueKey)
                            .foregroundStyle(Theme.Palette.accent)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.xsmall)
                        Text(verbatim: TrackerText.duration(minutes: entry.item.minutes))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(Theme.Typography.caption)
                    .help(entry.summary)
                }
                if day.entries.count > Self.entriesPerCell {
                    Text(verbatim: String(format: relayLocalized("+%d more"), day.entries.count - Self.entriesPerCell))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TimesheetText.background(of: day, isToday: isToday))
            .overlay(Rectangle().strokeBorder(Theme.Palette.border, lineWidth: 0.5))
            .opacity(day.isInPeriod ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }
}

// MARK: - Pieces

/// What a day came to against what it asks for, coloured by how far along it
/// is: short of it amber, there green. A day off says only what was done on it.
private struct DayTotal: View {
    let day: Timesheet.Day

    var body: some View {
        if day.expected > 0 {
            Badge(
                String(
                    format: relayLocalized("%@ of %@"),
                    TrackerText.duration(minutes: day.minutes),
                    TrackerText.duration(minutes: day.expected)
                ),
                tint: tint
            )
            .monospacedDigit()
            .fixedSize()
        } else if day.minutes > 0 {
            Badge(TrackerText.duration(minutes: day.minutes), tint: Theme.Palette.textSecondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private var tint: Color {
        if day.minutes >= day.expected { return Theme.Palette.statusFinished }
        return day.minutes > 0 ? Theme.Palette.statusWaiting : Theme.Palette.textTertiary
    }
}

@MainActor
private enum TimesheetText {
    /// `ПН`, `MON`: in the window's language rather than the Mac's.
    static func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Localization.shared.locale).weekday(.abbreviated)).uppercased()
    }

    /// Today stands out the way it does in the tracker's own timesheet, and a
    /// day off is set a shade apart from the days that ask for time.
    static func background(of day: Timesheet.Day, isToday: Bool) -> Color {
        if isToday { return Theme.Palette.accentMuted.opacity(0.55) }
        return day.expected == 0 ? Theme.Palette.surface : Color.clear
    }
}
