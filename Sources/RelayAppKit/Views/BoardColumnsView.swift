import RelayTracker
import RelayUI
import SwiftUI

/// A board's columns as a list, the way the tracker's own board settings lay
/// them out: dragged into order, merged, taken off and added back.
///
/// Opened over the board rather than in place of it, so every change is seen
/// on the board behind as it is made; there is nothing to save, and Done only
/// closes the panel.
struct BoardColumnsView: View {
    @Environment(AppModel.self) private var model
    let boardID: String

    private var tracker: TrackerController { model.tracker }
    private var snapshot: BoardSnapshot? { tracker.snapshots[boardID] }
    private var layout: BoardLayout { tracker.layout(of: boardID) }

    var body: some View {
        ModalSurface(relayLocalized("Board Columns"), onDismiss: { model.dismissModal() }) {
            if let snapshot {
                content(snapshot)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            HStack(spacing: Theme.Spacing.small) {
                RelayButton(relayLocalized("Columns as in the Tracker"), kind: .ghost) {
                    tracker.changeLayout(of: boardID) { $0 = BoardLayout() }
                }
                .disabled(layout.isEmpty)
                Spacer()
                RelayButton(relayLocalized("Done"), kind: .primary) { model.dismissModal() }
            }
        }
    }

    private func content(_ snapshot: BoardSnapshot) -> some View {
        let lanes = layout.lanes(of: snapshot.columns)
        let shown = lanes.filter(layout.shows)
        let hidden = lanes.filter { !layout.shows($0) }
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    if let field = snapshot.columnField {
                        Text(String(format: relayLocalized("The board's columns are the values of %@"), field))
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    Text(relayLocalized("Laid out for you alone: the board in the tracker, and how everyone else sees it, stay as they are."))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if shown.isEmpty {
                    Text(relayLocalized("Every column is hidden"))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ReorderableColumn(
                        ids: shown.map(\.id),
                        spacing: Theme.Spacing.xsmall,
                        space: "relay.board-columns",
                        onMove: { moved, target, side in
                            guard let lane = shown.first(where: { $0.id == moved }),
                                  let beside = shown.first(where: { $0.id == target })
                            else { return }
                            tracker.changeLayout(of: boardID) {
                                $0.move(lane, beside: beside, side: side, in: snapshot.columns)
                            }
                        }
                    ) { id in
                        if let index = shown.firstIndex(where: { $0.id == id }) {
                            BoardColumnRow(
                                boardID: boardID,
                                number: index + 1,
                                lane: shown[index],
                                others: shown.filter { $0.id != id },
                                snapshot: snapshot
                            )
                        }
                    }
                }

                if hidden.isEmpty {
                    Text(relayLocalized("Every column of the board is shown."))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                } else {
                    addMenu(hidden, snapshot: snapshot)
                }
            }
            .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
            .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
        }
    }

    /// The hidden columns, each with how many cards it holds — which is what
    /// says whether one is worth putting back.
    private func addMenu(_ hidden: [BoardLane], snapshot: BoardSnapshot) -> some View {
        Menu {
            ForEach(hidden) { lane in
                Button {
                    tracker.changeLayout(of: boardID) { $0.show(lane, in: snapshot.columns) }
                } label: {
                    Text(verbatim: "\(lane.title) · \(lane.cards(in: snapshot).count)")
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(relayLocalized("Add Column"))
                    .font(Theme.Typography.row)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.accent)
            .padding(.vertical, Theme.Spacing.xsmall)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
    }
}

/// One column in the list: where it stands, what it is, and what can be done
/// with it.
private struct BoardColumnRow: View {
    @Environment(AppModel.self) private var model
    let boardID: String
    let number: Int
    let lane: BoardLane
    /// The other columns on show, which this one can be merged into.
    let others: [BoardLane]
    let snapshot: BoardSnapshot

    @State private var isHovering = false

    private var tracker: TrackerController { model.tracker }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                .frame(width: 14)
                .relayTooltip(relayLocalized("Drag to change the order"))
            Text(verbatim: "\(number)")
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 18, alignment: .trailing)

            title

            Spacer(minLength: Theme.Spacing.small)

            if let limit = lane.limit {
                Text(String(format: relayLocalized("At most %d"), limit))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize()
                    .relayTooltip(relayLocalized("Set on the board in the tracker"))
            }
            Text(verbatim: "\(lane.cards(in: snapshot).count)")
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(minWidth: 20, alignment: .trailing)
                .relayTooltip(relayLocalized("Cards in the column"))

            mergeMenu

            IconButton(systemImage: "xmark", size: Theme.Metrics.action) {
                tracker.changeLayout(of: boardID) { $0.hide(lane) }
            }
            .relayTooltip(relayLocalized("Hide Column"))
        }
        .padding(.leading, Theme.Spacing.small)
        .padding(.trailing, Theme.Spacing.xsmall)
        .frame(height: 40)
        .background(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// One name, or a merged column's names as chips, each of which can be
    /// taken out again — the first says where a dropped card goes, since that
    /// is the one thing about a merged column its title cannot say.
    @ViewBuilder
    private var title: some View {
        if lane.isMerged {
            HStack(spacing: Theme.Spacing.xsmall) {
                ForEach(lane.columns) { column in
                    memberChip(column)
                }
            }
        } else {
            Text(verbatim: lane.title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
    }

    private func memberChip(_ column: BoardColumn) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: column.title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .relayTooltip(
                    String(format: relayLocalized("Cards dropped on this column go to %@"), column.title),
                    isEnabled: column == lane.destination
                )
            Button {
                tracker.changeLayout(of: boardID) { $0.detach(column, in: snapshot.columns) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .relayTooltip(relayLocalized("Give it a column of its own"))
        }
        .padding(.leading, Theme.Spacing.small)
        .padding(.trailing, Theme.Spacing.xxsmall)
        .frame(height: 24)
        .background(Theme.Palette.surfaceActive)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private var mergeMenu: some View {
        Menu {
            ForEach(others) { other in
                Button(other.title) {
                    tracker.changeLayout(of: boardID) { $0.merge(lane, into: other, in: snapshot.columns) }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(relayLocalized("Merge With"))
                    .font(Theme.Typography.rowSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, Theme.Spacing.small)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
        .disabled(others.isEmpty)
    }
}
