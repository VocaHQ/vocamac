// TranscriptionWorkflowComponents.swift
// VocaMac

import SwiftUI

/// Compact title treatment for focused utility windows. These workflows do
/// one job, so they do not need the full settings-page header footprint.
struct TranscriptionWorkflowHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(VocaDesign.accent)
                .frame(width: 34, height: 34)
                .background(VocaDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bounded transcript surface shared by file and system-audio workflows.
/// Long results scroll inside the card instead of making the whole window tall.
struct WorkflowTranscriptCard: View {
    let text: String
    let detail: String
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button(action: copy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 84, maxHeight: .infinity)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vocaCard()
    }
}
