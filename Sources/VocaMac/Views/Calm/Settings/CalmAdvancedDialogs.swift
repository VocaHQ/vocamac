// CalmAdvancedDialogs.swift
// VocaMac
//
// Settings › Advanced › Phone gateway › Pair phone…: the QR code VocaPhone
// scans (gateway address and bearer token), three steps, and the address
// to copy.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The pairing dialog (Dialogs board, “Phone gateway”): 460 wide, a QR
/// code on the left and the steps on the right.
struct CalmGatewayPairDialog: View {
    /// The compact JSON the QR encodes; nil when there's no pairing yet.
    let payload: String?
    let url: String?
    let onCopyURL: () -> Void

    @State private var qrImage: NSImage?
    @State private var copied = false

    var body: some View {
        CalmDialog(
            "Phone gateway",
            description: "Dictate on your phone and type on this Mac. Both must be on the same network.",
            width: 460
        ) {
            HStack(alignment: .center, spacing: 16) {
                qrCode
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open VocaPhone on your phone")
                    Text("2. Scan the code")
                    Text("3. Keep the page open and talk")
                }
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let url {
                Text(url)
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, -6)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", onPrimary: {}, leading: {
                if url != nil {
                    Button(copied ? "Copied" : "Copy URL", action: copy).calmButton(.quiet)
                }
            })
        }
        .onAppear { qrImage = payload.flatMap { GatewayQRCodeImage.make(from: $0) } }
    }

    /// 120-point tile. A real code sits on white with a quiet zone so a
    /// phone can read it in dark mode too.
    @ViewBuilder
    private var qrCode: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if let qrImage {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .frame(width: 120, height: 120)
                .background(shape.fill(Color.white))
                .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
                .accessibilityLabel("Pairing QR code")
        } else {
            Text("Couldn’t make a QR code")
                .font(.system(size: 11))
                .foregroundStyle(CalmColor.muted)
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(width: 120, height: 120)
                .background(shape.fill(CalmColor.panel))
                .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
        }
    }

    private func copy() {
        onCopyURL()
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - QR helper

enum GatewayQRCodeImage {
    static func make(from string: String) -> NSImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(trimmed.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
