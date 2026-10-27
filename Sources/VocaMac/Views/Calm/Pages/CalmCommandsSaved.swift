// CalmCommandsSaved.swift
// VocaMac
//
// The Commands page's Saved commands section: a serif title with Create
// new, then a three-column grid of command cards (keys, name, instruction).
// With none saved, a card offers the starter set instead. Create new is the
// one way to start a command; a dashed “Create your own” card repeated it.

import SwiftUI

/// Saved commands: title, Create new, and the card grid.
struct CalmSavedCommandsSection: View {
    let onCreate: () -> Void
    let onEdit: (SavedCommand) -> Void

    @EnvironmentObject private var appState: AppState

    private static let columns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CalmSectionTitle("Saved commands")
                Spacer(minLength: 0)
                Button(action: onCreate) { CalmButtonLabel("Create new", icon: .plus) }
                    .calmButton(.primary)
            }
            grid
        }
    }

    private var cells: [Cell] {
        let commands = appState.savedCommands
        return commands.isEmpty ? [Cell.starters] : commands.map(Cell.command)
    }

    private var grid: some View {
        let rows = stride(from: 0, to: cells.count, by: Self.columns).map { start in
            Array(cells[start..<min(start + Self.columns, cells.count)])
        }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { cell in
                        view(for: cell)
                            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
                    }
                    // Keep the last row's cards a third wide.
                    ForEach(0..<(Self.columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1).gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for cell: Cell) -> some View {
        switch cell {
        case .command(let command):
            CalmSavedCommandCard(command: command) { onEdit(command) }
        case .starters:
            CalmStarterCommandsCard { appState.addStarterCommands() }
        }
    }

    private enum Cell: Identifiable {
        case command(SavedCommand)
        case starters

        var id: String {
            switch self {
            case .command(let command): return command.id.uuidString
            case .starters: return "starters"
            }
        }
    }
}

// MARK: - Cards

/// One saved command: its keys (or how to run it without), name and
/// instruction, on an outlined content card. Click to edit.
private struct CalmSavedCommandCard: View {
    let command: SavedCommand
    let onEdit: () -> Void

    @State private var isHovered = false

    private var combo: HotKeyCombo? { HotKeyCombo(storageString: command.shortcut) }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 10) {
                keys
                VStack(alignment: .leading, spacing: 10) {
                    Text(CalmCommandsText.commandName(command))
                        .font(CalmFont.sf(14.5, weight: 600))
                        .foregroundStyle(CalmColor.ink)
                        .lineLimit(1)
                    Text(command.instruction.isEmpty ? "No instruction yet" : command.instruction)
                        .calmType(.description)
                        .foregroundStyle(CalmColor.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .calmCard()
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    CalmIcon(.edit, size: 15)
                        .foregroundStyle(CalmColor.muted)
                        .padding(16)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous))
        }
        .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.panel))
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Edit")
    }

    @ViewBuilder
    private var keys: some View {
        if let combo {
            CalmKeyCombo(combo: combo)
        } else {
            // The same height as the caps, so cards line up.
            Text("No shortcut · say its name")
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .frame(height: CalmMetrics.keyCapHeight)
        }
    }

    private var accessibilityText: String {
        var text = CalmCommandsText.commandName(command)
        if let combo { text += ", shortcut \(KeyCodeReference.displayName(for: combo))" }
        return text + ". " + command.instruction
    }
}

/// With nothing saved yet: offer the three starters in one click.
private struct CalmStarterCommandsCard: View {
    let onAdd: () -> Void

    private var names: String {
        let names = SavedCommand.starters.map(\.name)
        guard let last = names.last else { return "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No saved commands yet")
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .frame(height: CalmMetrics.keyCapHeight)
            VStack(alignment: .leading, spacing: 10) {
                Text("Start with three")
                    .font(CalmFont.sf(14.5, weight: 600))
                    .foregroundStyle(CalmColor.ink)
                Text("\(names). Say a name in Command Mode, or add a shortcut later.")
                    .calmType(.description)
                    .foregroundStyle(CalmColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            Button("Add them", action: onAdd)
                .calmButton(.secondary, size: .small)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .calmCard()
    }
}
